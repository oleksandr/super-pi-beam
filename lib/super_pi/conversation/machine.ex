defmodule SuperPi.Conversation.Machine do
  @moduledoc """
  Runtime Conversation Turn Coordinator (`:gen_statem` with `[:handle_event_function, :state_enter]`)
  synchronized with durable `Fsmx` tasks (`SuperPi.Durable.TaskEngine`) and the 12-hook
  `SuperPi.Extension` pipeline (`REQ-FSM-01`..`REQ-FSM-06`, `09 - Data Flows and Extension Injection Points.md`).

  ## States
  - `:recovering` — Runs `TaskEngine.reconcile_on_open!/1` on startup and transitions to `:idle`.
  - `:idle` — Accepts `submit/3` (`:queue`, `:steer`, `:write`) and manual `compact/2`.
  - `:preparing_request` — Runs `before_agent_start`, derives context (`Context.derive/1`), runs `before_request` and `before_provider_request`.
  - `:streaming_llm` — Streams or invokes the configured `llm_responder` and normalizes events; handles mid-stream `:steer` preemption.
  - `:executing_tools` — Runs tool calls one at a time: `before_tool` in the machine, then `wrap_tool` -> `SandboxRunner` -> `after_tool` in a task, so the machine still answers `cancel`, `steer` and `get_state` while a tool runs. Then `after_tools`. A `:steer` lets the running tool finish and skips the rest of the batch.
  - `:sleeping_backoff` — Pauses turn execution when provider rate-limits/retries occur (`TaskEngine.sleep_until/3`).
  - `:awaiting_children` — A tool result carried the `control` directive `%{"await" => ...}`
    (`delegate_subagent`). The durable task is `waiting` on its child tasks and the machine parks, like
    `:sleeping_backoff`, still answering `cancel`, `get_state` and `compact`. A child that settles wakes
    the task and tells the machine (`{:task_woken, task_id}`, from `TaskEngine`, on any node). A poll
    (`config :super_pi, :await_poll_ms`, default 5 s) covers a lost message. On wake the machine stores
    one user message per child with its summary and goes on at `:preparing_request`. Not a tool result:
    the tool call already has one (the acknowledgement), and a second result for one call id is refused
    by the providers.
  - `:compacting` — Runs `before_compact` or default compaction and records `pi.compaction` with `head_entry_id`.
  - `:settling_run` — Runs `after_run` verification gate; either loops back to `:preparing_request` (`{:continue, prompt}`) or completes the durable `pi.generation` task and returns to `:idle`.
  """

  @behaviour :gen_statem

  @steer_skip_text "Tool call skipped: the user steered the conversation."

  require Logger

  alias SuperPi.Durable.{Context, DeferredFlusher, Doc, Storage, TaskEngine}
  alias SuperPi.Durable.Schemas.Task, as: TaskSchema
  alias SuperPi.Env.SandboxRunner
  alias SuperPi.Event
  alias SuperPi.Extension

  defstruct [
    :conversation_id,
    :active_task_id,
    :llm_responder,
    :tool_executor,
    :active_llm_task,
    # %{task: Task.t(), call: tool_call} while a tool runs.
    :active_tool,
    retry_count: 0,
    extensions: [],
    pending_tool_calls: [],
    completed_tool_results: [],
    steer_preempted: false,
    # Steer texts, newest first, stored when the running step ends (`flush_steer_messages/1`).
    steer_messages: [],
    last_assistant_message: nil,
    reply_from: nil,
    turn_span: nil,
    turn_task_id: nil,
    turn_status: :ok,
    # The `await` directive of the tool batch: %{"task_ids", "policy", "children"}.
    await: nil,
    # A resumed turn of a subagent child has no caller, so the machine stops when the turn ends.
    stop_when_done: false
  ]

  @impl :gen_statem
  def callback_mode, do: [:handle_event_function, :state_enter]

  # A machine that stops mid-turn still ends its turn span, so the span is exported.
  @impl :gen_statem
  def terminate(reason, _state, %__MODULE__{turn_span: span}) when not is_nil(span) do
    SuperPi.Telemetry.turn_stop(span, {:error, {:machine_stopped, reason}})
  end

  def terminate(_reason, _state, _data), do: :ok

  # --- Public Client API ---

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }
  end

  def start_link(opts) do
    conv_id = Keyword.fetch!(opts, :conversation_id)

    # The name is registered in `Horde.Registry`, which removes the entry of a machine that has just
    # exited a moment after it ends. Until then a new machine cannot take the name. `start_link`
    # would kill its caller with that failure, so start unlinked, retry, then link.
    case start_registered(conv_id, opts, 100) do
      {:ok, pid} ->
        Process.link(pid)
        {:ok, pid}

      other ->
        other
    end
  end

  defp start_registered(conv_id, opts, tries) do
    case :gen_statem.start(via_tuple(conv_id), __MODULE__, opts, []) do
      {:error, {:process_not_registered_via, _}} when tries > 0 ->
        Process.sleep(10)
        start_registered(conv_id, opts, tries - 1)

      other ->
        other
    end
  end

  def via_tuple(conversation_id) do
    {:via, Horde.Registry, {SuperPi.Conversation.Locator.registry(), SuperPi.Conversation.Locator.key(conversation_id)}}
  end

  @doc """
  Cancels the running turn: stops the LLM request or the running tool (with its OS processes),
  records a "cancelled" result for every tool call without a result, marks the durable task
  `cancelled`, replies `{:error, :cancelled}` to the waiting submit caller and returns to `:idle`.

  The subtree goes with it: the task's live children (subagents, also while the turn is parked in
  `:awaiting_children`) are aborted bottom-up by `TaskEngine.cancel_task/2`, which calls
  `abort_task!/1` on each, and the machines of those children are cancelled.
  """
  def cancel(pid_or_via) do
    :gen_statem.cast(pid_or_via, :cancel)
  end

  @doc """
  Tells the machine that a pending `pi.generation` task was stored for it (a scheduled run, see
  `SuperPi.Schedule`). An idle machine starts the task at once. A busy one starts it when its
  turn ends. A machine that is still recovering finds the task itself.
  """
  def resume_pending(pid_or_via) do
    :gen_statem.cast(pid_or_via, :resume_pending)
  end

  @doc """
  `submit/3` for entry points (gateway, RPC): a machine that exits or a call that times out is
  `{:error, reason}`, not an exit of the caller.
  """
  def safe_submit(pid_or_via, text, opts \\ []) do
    submit(pid_or_via, text, opts)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Submits user input with mode `:queue` (default), `:steer` (preempts active tool batch/stream), or `:write` (passive append).
  """
  def submit(pid_or_via, text, opts \\ []) when is_binary(text) do
    mode = Keyword.get(opts, :mode, :queue)
    timeout = Keyword.get(opts, :timeout, 30_000)
    :gen_statem.call(pid_or_via, {:submit, mode, text, opts}, timeout)
  end

  @doc """
  Runs manual compaction. During a turn the request waits until the conversation is idle, so a
  compaction never lands between a tool call and its result. `opts[:timeout]` (default 30 s)
  bounds the wait. Returns `{:ok, :noop}`, `{:ok, :cancelled}` or `{:ok, result}`.
  """
  def compact(pid_or_via, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, 30_000)
    :gen_statem.call(pid_or_via, {:compact, opts}, timeout)
  end

  @doc """
  Returns the current `{:state, data}` snapshot of the `:gen_statem`.
  """
  def get_state(pid_or_via) do
    :gen_statem.call(pid_or_via, :get_state)
  end

  @doc """
  Updates the active extension pipeline for the conversation machine.
  """
  def set_extensions(pid_or_via, extensions) when is_list(extensions) do
    :gen_statem.call(pid_or_via, {:set_extensions, extensions}, 5_000)
  end

  # --- :gen_statem Callbacks ---

  @impl :gen_statem
  def init(opts) do
    conv_id = Keyword.fetch!(opts, :conversation_id)
    extensions = Keyword.get(opts, :extensions, [])
    llm_responder = Keyword.get(opts, :llm_responder, &default_llm_responder/2)
    tool_executor = Keyword.get(opts, :tool_executor, &default_tool_executor/3)
    Logger.metadata(conversation_id: conv_id)

    data = %__MODULE__{
      conversation_id: conv_id,
      extensions: extensions,
      llm_responder: llm_responder,
      tool_executor: tool_executor
    }

    {:ok, :recovering, data, [{:next_event, :internal, :reconcile}]}
  end

  # A task that was running when the machine's node stopped is pending again after the reconcile.
  # Resume it from the durable state: the user message is already stored, and nobody waits for a
  # reply. `config :super_pi, resume_pending_turns: false` leaves such tasks alone.
  #
  # A turn parked on its children (`waiting`) is parked again. One that the children woke while no
  # machine ran (`pending`, phase `awaiting_children`) goes on with their results.
  defp resume_or_idle(%__MODULE__{} = data) do
    resume? = Application.get_env(:super_pi, :resume_pending_turns, true)
    parked = if resume?, do: TaskEngine.next_waiting_generation(data.conversation_id)
    pending = if resume? and is_nil(parked), do: TaskEngine.next_pending_generation(data.conversation_id)

    with %{id: _} = task <- parked || pending,
         {:ok, task} <- if(parked, do: {:ok, task}, else: TaskEngine.start_task(task.id)) do
      Logger.info("[Machine] resuming turn, task #{task.id}, attempt #{task.attempt}, status #{task.status}")
      Logger.metadata(task_id: task.id)
      turn_span = SuperPi.Telemetry.turn_start(data.conversation_id, task.id)

      next_data = %__MODULE__{
        data
        | active_task_id: task.id,
          turn_task_id: task.id,
          turn_span: turn_span,
          turn_status: :ok,
          stop_when_done: subagent_child?(data.conversation_id)
      }

      Event.publish(Event.turn_started(data.conversation_id, task.id, Storage.current_seq()))
      if task.status == "waiting", do: revive_subagents(task)

      if task.status == "waiting" or task.phase == "awaiting_children" do
        {:next_state, :awaiting_children, next_data, [{:next_event, :internal, :await_check}]}
      else
        {:next_state, :preparing_request, next_data, [{:next_event, :internal, :prepare}]}
      end
    else
      _ -> {:next_state, :idle, data}
    end
  end

  defp subagent_child?(conversation_id) do
    match?(%{"subagentTaskId" => id} when is_integer(id), Doc.snapshot("conversation", conversation_id, "pi.agent"))
  end

  # Starts the configured MCP servers (once per server) so their tools are in the catalog
  # before the first request. A failure is logged by the manager and never stops the conversation.
  defp start_mcp_clients(conv_id) do
    if Application.get_env(:super_pi, :mcp_clients, true) do
      agent = Doc.snapshot("conversation", conv_id, "pi.agent") || %{}

      opts =
        case Map.get(agent, "globalConfigDir") do
          dir when is_binary(dir) -> [global_config_dir: dir]
          _ -> []
        end

      SuperPi.MCP.Manager.ensure_started(opts)
      declare_mcp_tools(conv_id, agent)
    end

    :ok
  end

  # The agent document holds the tool list sent to the model, captured when the conversation was
  # configured. Add the MCP tools that were registered after that.
  defp declare_mcp_tools(conv_id, agent) do
    declared = agent |> Map.get("tools", []) |> Enum.map(& &1["name"]) |> MapSet.new()

    new_tools =
      SuperPi.Tools.active_llm_tools()
      |> Enum.filter(&(String.starts_with?(&1["name"], "mcp__") and not MapSet.member?(declared, &1["name"])))

    if new_tools != [] do
      Storage.configure_agent!(conv_id, %{"tools" => Map.get(agent, "tools", []) ++ new_tools})
    end
  end

  # --- State: :recovering ---

  @impl :gen_statem
  def handle_event(:enter, _old_state, :recovering, data) do
    publish_live_state(data, "recovering")
    :keep_state_and_data
  end

  def handle_event(:internal, :reconcile, :recovering, data) do
    # MCP servers start here, not in `init/1`: `init` runs inside the supervisor's start call, and
    # a slow server would block every other machine start. The first request still waits for it.
    try do
      start_mcp_clients(data.conversation_id)
      _reconciled = TaskEngine.reconcile_on_open!(data.conversation_id)
      # Scratch directories left by tasks that ended while no machine ran (a crash, a failover).
      SuperPi.Env.Workspace.sweep()
      resume_or_idle(data)
    rescue
      e ->
        # The database is unreachable, say. Stop with a `:shutdown` reason: a supervisor does not
        # restart a transient child for it, so a failing conversation cannot drain the restart budget
        # that every conversation shares. The next request starts the machine again.
        Logger.error("[Machine] recovery failed for conversation #{data.conversation_id}: #{Exception.message(e)}")
        {:stop, {:shutdown, {:recovery_failed, Exception.message(e)}}}
    end
  end

  # --- State: :idle ---

  def handle_event(:enter, _old_state, :idle, %__MODULE__{} = data) do
    publish_live_state(data, "idle")
    publish_turn_end(data)
    Logger.metadata(task_id: nil)
    SuperPi.Telemetry.turn_stop(data.turn_span, data.turn_status)
    # The task ended, so its scratch workspace is no longer needed.
    SuperPi.Env.Workspace.cleanup_scratch(data.conversation_id, data.turn_task_id)
    settle_subagent_task(data)

    reset = %__MODULE__{
      data
      | active_task_id: nil,
        steer_preempted: false,
        steer_messages: [],
        active_tool: nil,
        pending_tool_calls: [],
        completed_tool_results: [],
        await: nil,
        turn_span: nil,
        turn_task_id: nil,
        turn_status: :ok
    }

    if data.stop_when_done and not is_nil(data.turn_task_id),
      do: {:stop, :normal, reset},
      else: {:keep_state, reset}
  end

  def handle_event({:call, from}, :get_state, state, data) do
    {:keep_state_and_data, [{:reply, from, {state, data}}]}
  end

  def handle_event({:call, from}, {:set_extensions, extensions}, _state, %__MODULE__{} = data) do
    {:keep_state, %__MODULE__{data | extensions: extensions}, [{:reply, from, :ok}]}
  end

  def handle_event(:cast, :cancel, :idle, _data) do
    :keep_state_and_data
  end

  def handle_event(:cast, :resume_pending, :idle, %__MODULE__{} = data) do
    case resume_or_idle(data) do
      {:next_state, :idle, _data} -> :keep_state_and_data
      other -> other
    end
  end

  def handle_event(:cast, :resume_pending, _busy_state, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  def handle_event(:cast, :cancel, _state, %__MODULE__{} = data) do
    shutdown_task(data.active_llm_task)

    # Killing the tool task ends its sandbox task and the OS processes under it.
    running_call =
      case data.active_tool do
        %{task: task, call: call} ->
          shutdown_task(task)
          [call]

        nil ->
          []
      end

    record_skipped_results(data.conversation_id, running_call ++ data.pending_tool_calls, "Tool call cancelled by the user.")
    data = flush_steer_messages(data)

    if data.active_task_id do
      # The children of a parked turn: `cancel_task/2` aborts their tasks (the subtree), then their
      # machines stop. A child machine that kept running would go on spending tokens for nobody.
      children = data.active_task_id |> TaskEngine.live_children() |> Enum.filter(&(&1.kind == "pi.subagent"))
      data.active_task_id |> TaskEngine.cancel_task(%{"reason" => "cancelled"}) |> check_task(data.active_task_id, "cancel")
      stop_subagents(children)
    end

    replies = if data.reply_from, do: [{:reply, data.reply_from, {:error, :cancelled}}], else: []

    {:next_state, :idle,
     %__MODULE__{
       data
       | reply_from: nil,
         turn_status: {:error, :cancelled},
         active_task_id: nil,
         active_llm_task: nil,
         active_tool: nil,
         pending_tool_calls: [],
         completed_tool_results: [],
         await: nil,
         retry_count: 0
     }, replies}
  end

  # Passive `:write` submission in ANY state appends to history without triggering generation
  def handle_event({:call, from}, {:submit, :write, text, _opts}, _state, %__MODULE__{} = data) do
    entry =
      Storage.append_entry!(data.conversation_id, "pi.message", %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => text}]
      })

    {:keep_state_and_data, [{:reply, from, {:ok, %{mode: :write, entry_id: entry.id}}}]}
  end

  def handle_event({:call, from}, {:submit, mode, raw_text, submit_opts}, :idle, %__MODULE__{} = data)
      when mode in [:queue, :steer] do
    ctx = hook_ctx(data)

    case Extension.run_on_input(data.extensions, raw_text, ctx) do
      :handled ->
        {:keep_state_and_data, [{:reply, from, {:ok, :handled_by_extension}}]}

      {:continue, transformed_text, media} ->
        content_items =
          [%{"type" => "text", "text" => transformed_text}] ++
            case media do
              m when is_list(m) -> m
              _ -> []
            end

        Storage.append_entry!(data.conversation_id, "pi.message", %{
          "role" => "user",
          "content" => content_items
        })

        {:ok, gen_task} =
          TaskEngine.create_task(data.conversation_id, "pi.generation", %{"prompt" => transformed_text})

        {:ok, running_task} = TaskEngine.start_task(gen_task.id)
        Logger.metadata(task_id: running_task.id)

        # The turn span is current in this process until the conversation is idle again.
        turn_span = SuperPi.Telemetry.turn_start(data.conversation_id, running_task.id, Keyword.get(submit_opts, :otel_ctx))

        next_data = %__MODULE__{
          data
          | turn_span: turn_span,
            turn_task_id: running_task.id,
            turn_status: :ok,
            active_task_id: running_task.id,
            reply_from: from,
            steer_preempted: false
        }

        Event.publish(Event.turn_started(data.conversation_id, running_task.id, Storage.current_seq()))
        {:next_state, :preparing_request, next_data, [{:next_event, :internal, :prepare}]}
    end
  end

  def handle_event({:call, from}, {:compact, opts}, :idle, %__MODULE__{} = data) do
    {:next_state, :compacting, %__MODULE__{data | reply_from: from}, [{:next_event, :internal, {:run_compaction, opts}}]}
  end

  # A parked turn has no tool call without a result, so compaction is safe and the caller need not wait.
  def handle_event({:call, from}, {:compact, opts}, :awaiting_children, %__MODULE__{} = data) do
    {:keep_state_and_data, [{:reply, from, compact_history(data, opts)}]}
  end

  # Compaction during a turn could cut between a tool call and its result: wait for `:idle`.
  def handle_event({:call, _from}, {:compact, _opts}, state, _data) when state != :idle do
    {:keep_state_and_data, [:postpone]}
  end

  # --- Queued `:queue` submissions while busy use `:postpone` (`REQ-FSM-03`) ---
  def handle_event({:call, _from}, {:submit, :queue, _text, _opts}, busy_state, _data)
      when busy_state not in [:idle, :recovering] do
    {:keep_state_and_data, [:postpone]}
  end

  # --- Preemptive `:steer` submission while executing tools or streaming (`REQ-FSM-03`) ---
  # The running step finishes first. The steer text is stored after the assistant entry and the
  # results of all its tool calls, so no user entry ever splits a tool call from its result.
  def handle_event({:call, from}, {:submit, :steer, text, _opts}, busy_state, %__MODULE__{} = data)
      when busy_state in [:streaming_llm, :executing_tools] do
    {:keep_state, %__MODULE__{data | steer_preempted: true, steer_messages: [text | data.steer_messages]},
     [{:reply, from, {:ok, :steered}}]}
  end

  # The rate-limited attempt stored no assistant entry, so the steer text goes in now and the
  # turn starts again at once. The task leaves `sleeping`; its wake job then does nothing.
  def handle_event({:call, from}, {:submit, :steer, text, _opts}, :sleeping_backoff, %__MODULE__{} = data) do
    case data.active_task_id |> TaskEngine.start_task() |> check_task(data.active_task_id, "resume after steer") do
      :ok ->
        data = flush_steer_messages(%__MODULE__{data | steer_messages: [text | data.steer_messages]})
        {:next_state, :preparing_request, data, [{:reply, from, {:ok, :steered}}, {:next_event, :internal, :prepare}]}

      {:error, reason} ->
        {:next_state, :idle, data, actions} =
          finish_run_with_error(%__MODULE__{data | steer_messages: [text | data.steer_messages]}, {:task_transition_failed, reason})

        {:next_state, :idle, data, [{:reply, from, {:ok, :steered}} | actions]}
    end
  end

  # Wait for `:steer` if in other transitional states
  def handle_event({:call, _from}, {:submit, :steer, _text, _opts}, _other_state, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  # --- State: :preparing_request ---

  def handle_event(:enter, _old_state, :preparing_request, %__MODULE__{} = data) do
    publish_live_state(data, "preparing_request")
    :keep_state_and_data
  end

  def handle_event(:internal, :prepare, :preparing_request, %__MODULE__{} = data) do
    ctx = hook_ctx(data)

    agent_doc = Doc.snapshot("conversation", data.conversation_id, "pi.agent") || %{}
    mutated_agent = Extension.run_before_agent_start(data.extensions, agent_doc, ctx)

    if mutated_agent != agent_doc do
      Storage.configure_agent!(data.conversation_id, mutated_agent)
    end

    sections =
      case Map.get(mutated_agent, "systemSections") do
        list when is_list(list) -> list
        _ -> [%{"id" => "core", "content" => "You are Super-Pi-BEAM."}]
      end

    # Only tools that the workspace can serve are offered (`SuperPi.Env.Workspace`).
    tools = SuperPi.Env.Workspace.offered_tools(Map.get(mutated_agent, "tools", []), mutated_agent)

    # One read of the history serves the system-state check and the derivation.
    {visible, graph} = Context.visible_entries_with_graph(data.conversation_id)
    {_change, system_entry} = Context.ensure_system_state!(data.conversation_id, sections, tools, visible)
    derived = Context.derive(data.conversation_id, {visible ++ List.wrap(system_entry), graph})
    derived = Extension.run_before_request(data.extensions, derived, ctx)

    effective_payload_model =
      Map.get(derived, :model) || Map.get(mutated_agent, "model", "claude-sonnet-4-5")

    provider_payload = %{
      model: effective_payload_model,
      messages: derived.messages,
      system_sections: derived.system_sections,
      tools: derived.tools,
      json_schema: Map.get(mutated_agent, "jsonSchema")
    }

    case Extension.run_before_provider_request(data.extensions, provider_payload, ctx) do
      {:ok, final_payload} ->
        checkpoint =
          if data.active_task_id,
            do: data.active_task_id |> TaskEngine.checkpoint_task("streaming_llm", %{"model" => final_payload.model}) |> check_task(data.active_task_id, "checkpoint"),
            else: :ok

        case checkpoint do
          :ok -> {:next_state, :streaming_llm, data, [{:next_event, :internal, {:invoke_llm, final_payload}}]}
          {:error, reason} -> finish_run_with_error(data, {:task_transition_failed, reason})
        end

      {:abort, reason} ->
        finish_run_with_error(data, reason)
    end
  end

  # --- State: :streaming_llm ---

  def handle_event(:enter, _old_state, :streaming_llm, %__MODULE__{} = data) do
    publish_live_state(data, "streaming_llm")
    :keep_state_and_data
  end

  def handle_event(:internal, {:invoke_llm, payload}, :streaming_llm, %__MODULE__{} = data) do
    ctx = hook_ctx(data)
    responder = data.llm_responder
    log_metadata = Logger.metadata()
    otel_ctx = SuperPi.Telemetry.current_ctx()
    model = Map.get(payload, :model, "unknown")

    task =
      SandboxRunner.start_owned(fn ->
        Logger.metadata(log_metadata)
        SuperPi.Telemetry.attach(otel_ctx)

        try do
          SuperPi.Telemetry.llm_span(model, fn -> responder.(payload, ctx) end)
        rescue
          e -> {:error, {:raised, e}}
        catch
          :exit, reason -> {:error, {:exit, reason}}
        end
      end)

    {:keep_state, %__MODULE__{data | active_llm_task: task}}
  end

  def handle_event(:info, {ref, task_res}, :streaming_llm, %__MODULE__{active_llm_task: %Task{ref: ref}} = data) do
    Process.demonitor(ref, [:flush])
    next_data = %__MODULE__{data | active_llm_task: nil}
    ctx = hook_ctx(next_data)

    case task_res do
      {:ok, assistant_msg} ->
        usage = Map.get(assistant_msg, "usage") || %{}
        with {:ok, totals} <- record_usage!(next_data.conversation_id, usage) do
          Event.publish(Event.usage_updated(next_data.conversation_id, next_data.turn_task_id, totals))
        end

        # `after_response` runs before tool dispatch: what it returns is stored and dispatched.
        assistant_msg =
          try do
            case Extension.run_after_response(next_data.extensions, assistant_msg, ctx) do
              %{} = msg -> msg
              _ -> assistant_msg
            end
          rescue
            _ -> assistant_msg
          end

        content =
          case Map.get(assistant_msg, "content") do
            list when is_list(list) -> list
            _ -> []
          end

        Storage.append_entry!(next_data.conversation_id, "pi.message", %{
          "role" => "assistant",
          "content" => content,
          "usage" => usage
        })

        Event.publish(Event.message_completed(next_data.conversation_id, next_data.turn_task_id, "assistant", content, usage))

        tool_calls =
          content
          |> Enum.filter(fn b -> is_map(b) and Map.get(b, "type") == "tool_call" end)

        next_data = %__MODULE__{next_data | last_assistant_message: assistant_msg, retry_count: 0}

        cond do
          next_data.steer_preempted ->
            record_skipped_results(next_data.conversation_id, tool_calls, @steer_skip_text)

            {:next_state, :preparing_request, flush_steer_messages(next_data), [{:next_event, :internal, :prepare}]}

          tool_calls != [] ->
            if next_data.active_task_id do
              TaskEngine.checkpoint_task(next_data.active_task_id, "executing_tools", %{
                "toolCount" => length(tool_calls)
              })
            end

            send(self(), :next_tool)

            {:next_state, :executing_tools,
             %__MODULE__{next_data | pending_tool_calls: tool_calls, completed_tool_results: []}}

          true ->
            {:next_state, :settling_run, next_data, [{:next_event, :internal, :verify_run}]}
        end

      {:retry_after, delay_ms} ->
        # Watchers may already hold text deltas of this attempt. The next attempt streams its own.
        Event.publish(Event.stream_reset(next_data.conversation_id, next_data.turn_task_id, delay_ms))
        Event.publish(Event.notice(next_data.conversation_id, next_data.turn_task_id, "warning", "Rate limited, retrying in #{delay_ms} ms"))

        if next_data.retry_count < 3 do
          wake_at = DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)

          if next_data.active_task_id do
            next_data.active_task_id |> TaskEngine.sleep_until(wake_at, %{"phase" => "backoff"}) |> check_task(next_data.active_task_id, "sleep")
          end

          {:next_state, :sleeping_backoff, %__MODULE__{next_data | retry_count: next_data.retry_count + 1},
           [{:state_timeout, delay_ms, :wake_from_backoff}]}
        else
          if next_data.active_task_id do
            TaskEngine.fail_task(next_data.active_task_id, %{"error" => "Rate limit retry cap exceeded (3 attempts)"})
          end

          next_data = flush_steer_messages(next_data)

          actions =
            if next_data.reply_from do
              [{:reply, next_data.reply_from, {:error, :rate_limit_exceeded}}]
            else
              []
            end

          {:next_state, :idle, %__MODULE__{next_data | reply_from: nil, active_task_id: nil, retry_count: 0, turn_status: {:error, :rate_limit_exceeded}}, actions}
        end

      {:error, reason} ->
        err_msg =
          case reason do
            {:raised, %{message: msg}} -> msg
            {:raised, e} when is_exception(e) -> Exception.message(e)
            other -> inspect(other)
          end

        if next_data.active_task_id do
          TaskEngine.fail_task(next_data.active_task_id, %{"error" => err_msg})
        end

        next_data = flush_steer_messages(next_data)

        actions =
          if next_data.reply_from do
            [{:reply, next_data.reply_from, {:error, err_msg}}]
          else
            []
          end

        {:next_state, :idle, %__MODULE__{next_data | reply_from: nil, active_task_id: nil, retry_count: 0, turn_status: {:error, err_msg}}, actions}
    end
  end

  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, :streaming_llm, %__MODULE__{active_llm_task: %Task{ref: ref}} = data) do
    next_data = flush_steer_messages(%__MODULE__{data | active_llm_task: nil})

    if next_data.active_task_id do
      TaskEngine.fail_task(next_data.active_task_id, %{"error" => inspect(reason)})
    end

    actions =
      if next_data.reply_from do
        [{:reply, next_data.reply_from, {:error, reason}}]
      else
        []
      end

    {:next_state, :idle, %__MODULE__{next_data | reply_from: nil, active_task_id: nil, retry_count: 0, turn_status: {:error, reason}}, actions}
  end

  # --- State: :sleeping_backoff ---

  def handle_event(:enter, _old_state, :sleeping_backoff, %__MODULE__{} = data) do
    publish_live_state(data, "sleeping_backoff")
    :keep_state_and_data
  end

  def handle_event(:state_timeout, :wake_from_backoff, :sleeping_backoff, %__MODULE__{} = data) do
    resumed =
      if data.active_task_id,
        do: data.active_task_id |> TaskEngine.start_task() |> check_task(data.active_task_id, "wake"),
        else: :ok

    case resumed do
      :ok -> {:next_state, :preparing_request, data, [{:next_event, :internal, :prepare}]}
      {:error, reason} -> finish_run_with_error(data, {:task_transition_failed, reason})
    end
  end

  # --- State: :awaiting_children ---

  def handle_event(:enter, _old_state, :awaiting_children, %__MODULE__{} = data) do
    publish_live_state(data, "awaiting_children")
    :keep_state_and_data
  end

  def handle_event(:internal, :await_check, :awaiting_children, %__MODULE__{} = data), do: await_check(data)
  def handle_event(:state_timeout, :await_check, :awaiting_children, %__MODULE__{} = data), do: await_check(data)

  # From `TaskEngine`, after the commit that woke the task. A message for an older task is ignored.
  def handle_event(:info, {:task_woken, task_id}, :awaiting_children, %__MODULE__{active_task_id: task_id}),
    do: {:keep_state_and_data, [{:next_event, :internal, :await_check}]}

  # --- State: :executing_tools ---

  def handle_event(:enter, _old_state, :executing_tools, %__MODULE__{} = data) do
    publish_live_state(data, "executing_tools")
    :keep_state_and_data
  end

  def handle_event(event_type, :next_tool, :executing_tools, %__MODULE__{steer_preempted: true} = data)
      when event_type in [:internal, :info] do
    # A steer arrived mid-batch: the rest of the batch gets "skipped" results, then the steer
    # text goes in and the next request starts.
    record_skipped_results(data.conversation_id, data.pending_tool_calls, @steer_skip_text)
    data = flush_steer_messages(%__MODULE__{data | pending_tool_calls: []})
    next_after_tools(data)
  end

  def handle_event(event_type, :next_tool, :executing_tools, %__MODULE__{pending_tool_calls: []} = data)
      when event_type in [:internal, :info] do
    ctx = hook_ctx(data)
    results = Enum.reverse(data.completed_tool_results)

    has_terminate? =
      Enum.any?(results, fn res ->
        get_in(res, ["control", "terminate"]) == true
      end)

    if has_terminate? do
      {:next_state, :settling_run, data, [{:next_event, :internal, :settle}]}
    else
      after_tools_res =
        try do
          Extension.run_after_tools(data.extensions, results, ctx)
        rescue
          _ -> :continue
        end

      case after_tools_res do
        {:steer, steer_msg} ->
          Storage.append_entry!(data.conversation_id, "pi.message", %{
            "role" => "user",
            "content" => [%{"type" => "text", "text" => steer_msg}]
          })

          next_after_tools(data)

        {:handoff, handoff_cfg} ->
          Storage.configure_agent!(data.conversation_id, handoff_cfg)
          next_after_tools(data)

        :terminate ->
          {:next_state, :settling_run, data, [{:next_event, :internal, :settle}]}

        _other ->
          next_after_tools(data)
      end
    end
  end

  def handle_event(event_type, :next_tool, :executing_tools, %__MODULE__{pending_tool_calls: [tc | rest], active_tool: nil} = data)
      when event_type in [:internal, :info] do
    tool_name = Map.get(tc, "name", "unknown")
    tool_id = Map.get(tc, "id", "call_0")
    ctx = data |> hook_ctx() |> Map.put(:tool_call_id, tool_id)
    raw_args = Map.get(tc, "arguments", %{})
    data = %__MODULE__{data | pending_tool_calls: rest}

    before_tool_res =
      try do
        Extension.run_before_tool(data.extensions, tool_name, raw_args, ctx)
      rescue
        e -> {:block, "Extension error: #{Exception.message(e)}"}
      end

    case before_tool_res do
      {:block, reason} ->
        Event.publish(Event.tool_blocked(data.conversation_id, data.turn_task_id, tool_id, tool_name, reason))

        finish_tool(data, %{
          "tool_call_id" => tool_id,
          "name" => tool_name,
          "is_error" => true,
          "output" => "Blocked by extension: #{reason}",
          "structured_output" => nil,
          "details" => %{"blocked" => true}
        })

      decision when elem(decision, 0) in [:allow, :allow_overwritten] ->
        {validated_args, overwritten_keys} =
          case decision do
            {:allow, a} -> {a, []}
            {:allow_overwritten, a, keys} -> {a, keys}
          end

        Event.publish(Event.tool_started(data.conversation_id, data.turn_task_id, tool_id, tool_name, validated_args, overwritten_keys))

        log_metadata = Logger.metadata()
        otel_ctx = SuperPi.Telemetry.current_ctx()

        task =
          SandboxRunner.start_owned(fn ->
            Logger.metadata(log_metadata)
            SuperPi.Telemetry.attach(otel_ctx)
            run_tool_pipeline(data, tool_id, tool_name, validated_args, overwritten_keys, ctx, {log_metadata, otel_ctx})
          end)

        {:keep_state, %__MODULE__{data | active_tool: %{task: task, call: tc}}}
    end
  end

  def handle_event(:info, {ref, tool_result}, :executing_tools, %__MODULE__{active_tool: %{task: %Task{ref: ref}}} = data) do
    Process.demonitor(ref, [:flush])
    publish_tool_completed(data, tool_result)
    finish_tool(%__MODULE__{data | active_tool: nil}, tool_result)
  end

  # A hook raised in the tool task, or the task was killed.
  def handle_event(:info, {:DOWN, ref, :process, _pid, reason}, :executing_tools, %__MODULE__{active_tool: %{task: %Task{ref: ref}, call: tc}} = data) do
    tool_result = %{
      "tool_call_id" => Map.get(tc, "id", "call_0"),
      "name" => Map.get(tc, "name", "unknown"),
      "is_error" => true,
      "output" => "Tool execution error: #{inspect(reason)}",
      "structured_output" => nil,
      "details" => %{"crashed" => true}
    }

    publish_tool_completed(data, tool_result)
    finish_tool(%__MODULE__{data | active_tool: nil}, tool_result)
  end

  # --- State: :compacting ---

  def handle_event(:enter, _old_state, :compacting, %__MODULE__{} = data) do
    publish_live_state(data, "compacting")
    :keep_state_and_data
  end

  def handle_event(:internal, {:run_compaction, opts}, :compacting, %__MODULE__{} = data) do
    compaction_reply = compact_history(data, opts)

    actions =
      if data.reply_from do
        [{:reply, data.reply_from, compaction_reply}]
      else
        []
      end

    {:next_state, :idle, %__MODULE__{data | reply_from: nil}, actions}
  end

  # --- State: :settling_run ---

  def handle_event(:enter, _old_state, :settling_run, %__MODULE__{} = data) do
    publish_live_state(data, "settling_run")
    :keep_state_and_data
  end

  def handle_event(:internal, :verify_run, :settling_run, %__MODULE__{} = data) do
    ctx = hook_ctx(data)
    summary = %{last_message: data.last_assistant_message, conversation_id: data.conversation_id}

    case Extension.run_after_run(data.extensions, summary, ctx) do
      {:continue, verification_prompt} ->
        Storage.append_entry!(data.conversation_id, "pi.message", %{
          "role" => "user",
          "content" => [%{"type" => "text", "text" => verification_prompt}]
        })

        {:next_state, :preparing_request, data, [{:next_event, :internal, :prepare}]}

      :accept ->
        complete_run(data)
    end
  end

  def handle_event(:internal, :settle, :settling_run, %__MODULE__{} = data) do
    complete_run(data)
  end

  # --- Catch-all event handlers for unhandled messages ---

  def handle_event({:call, from}, msg, _state, _data) do
    {:keep_state_and_data, [{:reply, from, {:error, {:unhandled, msg}}}]}
  end

  def handle_event(_event_type, _event_content, _state, _data) do
    :keep_state_and_data
  end

  # --- Helpers ---

  # Completes the durable task, compacts if the policy says so and answers the submit caller.
  defp complete_run(%__MODULE__{} = data) do
    if data.active_task_id do
      data.active_task_id
      |> TaskEngine.complete_task(%{"assistantMessage" => data.last_assistant_message})
      |> check_task(data.active_task_id, "complete")
    end

    case SuperPi.Compaction.check_policy(data.conversation_id) do
      {:threshold, _} -> data.conversation_id |> SuperPi.Compaction.compact!(:threshold) |> then(&publish_compaction(data.conversation_id, &1))
      {:background, _} -> SuperPi.Compaction.compact!(data.conversation_id, :background, enqueue: true)
      :none -> :ok
    end

    actions = if data.reply_from, do: [{:reply, data.reply_from, {:ok, data.last_assistant_message}}], else: []

    {:next_state, :idle, %__MODULE__{data | active_task_id: nil, reply_from: nil, pending_tool_calls: [], completed_tool_results: []}, actions}
  end

  # Compacts and announces it. Runs in `:compacting`, and in `:awaiting_children`, where the history
  # is whole: every tool call has its result.
  defp compact_history(%__MODULE__{} = data, opts) do
    ctx = hook_ctx(data)
    {visible, _graph} = Context.visible_entries_with_graph(data.conversation_id)

    compaction_reply =
      case Extension.run_before_compact(data.extensions, %{entries: visible, opts: opts}, ctx) do
        :cancel ->
          {:ok, :cancelled}

        {:compacted, summary_text, custom_data} ->
          head_id = find_compaction_cutoff_id(visible)

          entry =
            Storage.append_entry!(
              data.conversation_id,
              "pi.compaction",
              Map.merge(%{"summary" => summary_text}, custom_data),
              head_entry_id: head_id
            )

          {:ok, %{entry_id: entry.id, summary: summary_text, head_entry_id: head_id}}

        :default ->
          case SuperPi.Compaction.compact!(data.conversation_id, :manual, opts) do
            {:ok, %{entry: entry, summary: summary_text, head_entry_id: head_id} = res} ->
              {:ok,
               %{
                 entry_id: entry.id,
                 summary: summary_text,
                 head_entry_id: head_id,
                 compacted_count: Map.get(res, :compacted_count),
                 kept_count: Map.get(res, :kept_count)
               }}

            {:ok, :noop} ->
              {:ok, :noop}
          end
      end

    publish_compaction(data.conversation_id, compaction_reply)
    compaction_reply
  end

  defp publish_compaction(conv_id, {:ok, %{head_entry_id: head, summary: summary}}),
    do: Event.publish(Event.compaction_completed(conv_id, head, summary))

  defp publish_compaction(_conv_id, _other), do: :ok

  defp finish_run_with_error(%__MODULE__{} = data, reason) do
    if data.active_task_id do
      TaskEngine.fail_task(data.active_task_id, %{"error" => inspect(reason)})
    end

    data = flush_steer_messages(data)

    actions =
      if data.reply_from do
        [{:reply, data.reply_from, {:error, reason}}]
      else
        []
      end

    {:next_state, :idle, %__MODULE__{data | active_task_id: nil, reply_from: nil, turn_status: {:error, reason}}, actions}
  end

  # Runs in the tool task: `wrap_tool` around the sandboxed executor, then `after_tool`.
  defp run_tool_pipeline(data, tool_id, tool_name, args, overwritten_keys, ctx, {log_metadata, otel_ctx}) do
    core_fn = fn exec_args ->
      case SandboxRunner.run_isolated(fn ->
             Logger.metadata(log_metadata)
             SuperPi.Telemetry.attach(otel_ctx)
             SuperPi.Telemetry.tool_span(tool_name, fn -> data.tool_executor.(tool_name, exec_args, ctx) end)
           end) do
        {:ok, %{} = res} ->
          Map.merge(
            %{
              "tool_call_id" => tool_id,
              "name" => tool_name,
              "is_error" => false,
              "output" => "",
              "structured_output" => nil,
              "details" => %{}
            },
            res
          )

        {:error, err} ->
          %{
            "tool_call_id" => tool_id,
            "name" => tool_name,
            "is_error" => true,
            "output" => "Tool execution error: #{inspect(err)}",
            "structured_output" => nil,
            "details" => err
          }
      end
    end

    # A plugin that answers in `wrap_tool` without calling the tool (a question, a permission refusal)
    # returns a result with no ids. The result of every call carries them.
    wrapped_res =
      %{"tool_call_id" => tool_id, "name" => tool_name, "is_error" => false, "output" => "", "structured_output" => nil, "details" => %{}}
      |> Map.merge(Extension.run_wrap_tool(data.extensions, tool_name, args, core_fn, ctx))

    final_res = Extension.run_after_tool(data.extensions, tool_name, args, wrapped_res, ctx)

    if overwritten_keys != [] do
      notice = "[Hook Notice: PreToolUse rewrote tool arguments for keys: #{Enum.join(overwritten_keys, ", ")}]\n"
      Map.update(final_res, "output", notice, &(notice <> to_string(&1)))
    else
      final_res
    end
  end

  defp publish_tool_completed(%__MODULE__{} = data, tool_result) do
    Event.publish(
      Event.tool_completed(
        data.conversation_id,
        data.turn_task_id,
        tool_result["tool_call_id"],
        tool_result["name"],
        Map.get(tool_result, "is_error", false),
        Map.get(tool_result, "output", "")
      )
    )
  end

  # Stores the result, applies its control directive and moves to the next call of the batch.
  defp finish_tool(%__MODULE__{} = data, tool_result) do
    append_tool_result!(data.conversation_id, tool_result)
    control = Map.get(tool_result, "control")
    apply_tool_control_directive(data.conversation_id, control)
    send(self(), :next_tool)
    {:keep_state, %__MODULE__{capture_await(data, control) | completed_tool_results: [tool_result | data.completed_tool_results]}}
  end

  # The `await` directive takes effect when the batch ends (`next_after_tools/1`): the other calls of
  # the batch still run. Directives of one batch add up, the last policy wins.
  defp capture_await(%__MODULE__{} = data, %{"await" => %{"task_ids" => ids} = await}) when is_list(ids) do
    prev = data.await || %{"task_ids" => [], "children" => []}

    %__MODULE__{
      data
      | await: %{
          "task_ids" => Enum.uniq(prev["task_ids"] ++ ids),
          "children" => prev["children"] ++ List.wrap(await["children"]),
          "policy" => await["policy"] || prev["policy"]
        }
    }
  end

  defp capture_await(%__MODULE__{} = data, _control), do: data

  defp next_after_tools(%__MODULE__{await: nil} = data), do: {:next_state, :preparing_request, data, [{:next_event, :internal, :prepare}]}
  defp next_after_tools(%__MODULE__{} = data), do: {:next_state, :awaiting_children, data, [{:next_event, :internal, :await_check}]}

  # --- Subagents ---

  # The turn of a subagent child ended. The worker that runs the child settles its task too; this
  # covers a turn that a restarted machine resumed after the worker's node was lost.
  defp settle_subagent_task(%__MODULE__{turn_task_id: nil}), do: :ok

  defp settle_subagent_task(%__MODULE__{} = data) do
    case Doc.snapshot("conversation", data.conversation_id, "pi.agent") do
      %{"subagentTaskId" => task_id} when is_integer(task_id) ->
        outcome =
          case data.turn_status do
            {:error, reason} -> {:error, reason}
            _ok -> {:ok, SuperPi.Workers.SubagentWorker.final_text(data.last_assistant_message)}
          end

        SuperPi.Workers.SubagentWorker.settle(task_id, outcome)

      _ ->
        :ok
    end
  rescue
    e -> Logger.error("[Machine] could not settle the subagent task: #{Exception.message(e)}")
  end

  # A parent that parks again after a node loss: a child that was running (or was reset by the
  # reconcile of this conversation) and has no machine lost it with its node, and Horde may not have
  # restarted it. Start it; its recovery resumes the turn and settles the task.
  defp revive_subagents(%TaskSchema{state: %{"children" => children}}) do
    children
    |> Enum.map(& &1["task_id"])
    |> TaskEngine.get_tasks()
    |> Enum.reject(&TaskSchema.terminal?/1)
    |> Enum.filter(&(&1.status == "running" or &1.attempt > 0))
    |> Enum.each(fn task ->
      child_id = task.input["child_conversation_id"]

      if is_integer(child_id) and is_nil(SuperPi.Conversation.Locator.whereis(child_id)) do
        SuperPi.Conversation.Locator.ensure_started(child_id, SuperPi.Workers.SubagentWorker.machine_opts(task.input["role"]))
      end
    end)
  end

  defp revive_subagents(_task), do: :ok

  # Cancels the machines of children whose tasks were aborted.
  defp stop_subagents(tasks) do
    Enum.each(tasks, fn task ->
      with child_id when is_integer(child_id) <- task.input["child_conversation_id"],
           pid when is_pid(pid) <- SuperPi.Conversation.Locator.whereis(child_id) do
        cancel(pid)
      end
    end)
  end

  defp await_poll_ms, do: Application.get_env(:super_pi, :await_poll_ms, 5_000)

  # Decides from the durable task, not from a message: the wake-up may have come before the machine
  # parked (the children were quick), or while no machine ran.
  defp await_check(%__MODULE__{} = data) do
    case TaskEngine.get_task(data.active_task_id) do
      %TaskSchema{status: "waiting"} ->
        {:keep_state_and_data, [{:state_timeout, await_poll_ms(), :await_check}]}

      %TaskSchema{status: status} = task when status in ["pending", "running"] ->
        resume_after_children(data, task)

      _gone_or_ended ->
        finish_run_with_error(data, :task_ended_while_waiting)
    end
  end

  defp resume_after_children(%__MODULE__{} = data, %TaskSchema{} = task) do
    started =
      case task.status do
        "pending" -> task.id |> TaskEngine.start_task() |> check_task(task.id, "wake")
        _running -> :ok
      end

    case started do
      :ok ->
        state = task.state || %{}
        children = if data.await, do: data.await["children"], else: state["children"] || []
        results = children |> Enum.map(& &1["task_id"]) |> TaskEngine.get_tasks()

        # `fail_fast`: the parent stopped waiting, so the children still running are stopped.
        if state["failedChildId"], do: stop_subagents(abort_live(results))

        Enum.each(TaskEngine.get_tasks(Enum.map(results, & &1.id)), &append_subagent_result!(data.conversation_id, &1))
        task.id |> TaskEngine.checkpoint_task("resumed_from_children", %{}) |> check_task(task.id, "resume after children")
        {:next_state, :preparing_request, %__MODULE__{data | await: nil}, [{:next_event, :internal, :prepare}]}

      {:error, reason} ->
        finish_run_with_error(data, {:task_transition_failed, reason})
    end
  end

  defp abort_live(tasks) do
    live = Enum.reject(tasks, &TaskSchema.terminal?/1)
    Enum.each(live, &TaskEngine.abort_task!(&1.id))
    live
  end

  # A user message, not a tool result: the call has its result (the acknowledgement) and a provider
  # refuses a second result for one call id.
  defp append_subagent_result!(conv_id, %TaskSchema{} = task) do
    role = task.input["role"] || "subagent"
    child = task.input["child_conversation_id"]
    result = task.result || %{}

    text =
      case task.status do
        "completed" -> "Subagent #{role} (conversation #{child}) finished:\n#{result["summary"]}"
        "failed" -> "Subagent #{role} (conversation #{child}) failed: #{result["error"]}"
        status -> "Subagent #{role} (conversation #{child}) did not finish (#{status})."
      end

    Storage.append_entry!(conv_id, "pi.message", %{
      "role" => "user",
      "content" => [%{"type" => "text", "text" => text}],
      "kind" => "subagent_result",
      "child_conversation_id" => child
    })
  end

  # A `pi.message` with role `tool` and the 3 result channels.
  defp append_tool_result!(conv_id, tool_result) do
    Storage.append_entry!(conv_id, "pi.message", %{
      "role" => "tool",
      "tool_call_id" => tool_result["tool_call_id"],
      "name" => tool_result["name"],
      "is_error" => tool_result["is_error"],
      "content" => tool_result["output"],
      "structured_output" => tool_result["structured_output"],
      "details" => tool_result["details"]
    })
  end

  # Every tool call of a stored assistant entry needs a result before the next user entry,
  # or the provider refuses the whole history (Anthropic and OpenAI return 400).
  defp record_skipped_results(conv_id, tool_calls, text) do
    Enum.each(tool_calls, fn tc ->
      append_tool_result!(conv_id, %{
        "tool_call_id" => Map.get(tc, "id") || "unknown",
        "name" => Map.get(tc, "name") || "unknown",
        "is_error" => true,
        "output" => text,
        "structured_output" => nil,
        "details" => %{"skipped" => true}
      })
    end)
  end

  defp flush_steer_messages(%__MODULE__{steer_messages: []} = data), do: %__MODULE__{data | steer_preempted: false}

  defp flush_steer_messages(%__MODULE__{} = data) do
    data.steer_messages
    |> Enum.reverse()
    |> Enum.each(fn text ->
      Storage.append_entry!(data.conversation_id, "pi.message", %{
        "role" => "user",
        "content" => [%{"type" => "text", "text" => text}],
        "steer" => true
      })
    end)

    %__MODULE__{data | steer_messages: [], steer_preempted: false}
  end

  # A refused task transition is logged, never ignored: a task left in the wrong state is
  # resumed or replayed later (Kanban Task 52).
  defp check_task({:ok, _task}, _task_id, _what), do: :ok
  defp check_task(%TaskSchema{}, _task_id, _what), do: :ok

  defp check_task({:error, reason}, task_id, what) do
    Logger.error("[Machine] task #{task_id}: #{what} refused: #{inspect(reason)}")
    {:error, reason}
  end

  defp shutdown_task(%Task{} = task) do
    Task.shutdown(task, :brutal_kill)
  rescue
    _ -> :ok
  end

  defp shutdown_task(_), do: :ok

  defp apply_tool_control_directive(_conv_id, nil), do: :ok

  defp apply_tool_control_directive(conv_id, %{} = control) do
    if is_list(control["add_tools"]) do
      agent = Doc.snapshot("conversation", conv_id, "pi.agent") || %{}
      existing = Map.get(agent, "tools", [])
      merged = Enum.uniq_by(existing ++ control["add_tools"], &Map.get(&1, "name"))
      Storage.configure_agent!(conv_id, %{"tools" => merged})
    end

    if is_map(control["handoff"]) do
      Storage.configure_agent!(conv_id, control["handoff"])
    end

    :ok
  end

  defp find_compaction_cutoff_id([]), do: nil

  defp find_compaction_cutoff_id(visible) do
    List.last(visible).id
  end

  defp publish_live_state(%__MODULE__{conversation_id: conv_id} = data, status) do
    DeferredFlusher.stage_deferred("conversation", conv_id, "pi.live", %{
      "status" => status,
      "updatedAt" => System.system_time(:millisecond)
    })

    Phoenix.PubSub.broadcast(
      SuperPi.PubSub,
      "conversation:#{conv_id}",
      {:conversation_state, conv_id, status}
    )

    Event.publish(Event.state_changed(conv_id, data.turn_task_id, status))
  end

  # The end of a turn is announced once, when the machine is idle again. `turn_status` says how it
  # ended. A conversation that never ran a turn (a manual compaction, a start-up) has no turn id.
  defp publish_turn_end(%__MODULE__{turn_task_id: nil}), do: :ok

  defp publish_turn_end(%__MODULE__{conversation_id: conv_id, turn_task_id: turn_id, turn_status: status} = data) do
    seq = Storage.current_seq()

    event =
      case status do
        {:error, :cancelled} -> Event.turn_cancelled(conv_id, turn_id, seq)
        {:error, reason} -> Event.turn_error(conv_id, turn_id, reason, seq)
        _ok -> Event.turn_completed(conv_id, turn_id, data.last_assistant_message, seq)
      end

    Event.publish(event)
  end

  defp hook_ctx(data) do
    agent = Doc.snapshot("conversation", data.conversation_id, "pi.agent") || %{}
    ws_paths = Map.get(agent, "workspacePaths") || []
    ws_root = List.first(ws_paths) || File.cwd!()

    %{
      conversation_id: data.conversation_id,
      active_task_id: data.active_task_id,
      workspace_root: ws_root,
      turn_id: data.turn_task_id,
      emit_event: fn ev -> Event.publish(Event.from_extension(data.conversation_id, data.turn_task_id, ev)) end
    }
  end

  defp default_llm_responder(payload, ctx) do
    model = to_string(Map.get(payload, :model, ""))
    conv_id = Map.get(ctx, :conversation_id)

    case SuperPi.AI.Providers.resolve(model) do
      {:ok, provider, effective_model} ->
        provider.generate(Map.put(payload, :model, effective_model), on_delta: &publish_delta(conv_id, Map.get(ctx, :turn_id), &1))

      {:error, reason} ->
        {:error, SuperPi.AI.Providers.format_error(reason)}
    end
  end

  defp publish_delta(conv_id, turn_id, event) do
    case event do
      {:text_delta, %{index: idx, delta: delta}} -> Event.publish(Event.text_delta(conv_id, turn_id, idx, delta))
      {:text_delta, idx, delta} -> Event.publish(Event.text_delta(conv_id, turn_id, idx, delta))
      {:thinking_delta, %{index: idx, delta: delta}} -> Event.publish(Event.thinking_delta(conv_id, turn_id, idx, delta))
      {:thinking_delta, idx, delta} -> Event.publish(Event.thinking_delta(conv_id, turn_id, idx, delta))
      {:toolcall_delta, %{index: idx, raw_json_delta: delta, partial_args: args}} -> Event.publish(Event.toolcall_delta(conv_id, turn_id, idx, delta, args))
      {:toolcall_delta, idx, delta, args} -> Event.publish(Event.toolcall_delta(conv_id, turn_id, idx, delta, args))
      _ -> :ok
    end
  end

  defp default_tool_executor(tool_name, args, ctx) do
    SuperPi.Tools.execute(tool_name, args, ctx)
  end

  defp record_usage!(conversation_id, usage) when is_map(usage) do
    in_tok = Map.get(usage, "input_tokens") || Map.get(usage, :input_tokens) || 0
    out_tok = Map.get(usage, "output_tokens") || Map.get(usage, :output_tokens) || 0

    Storage.commit(fn seq ->
      # Read inside the transaction, from the database, so concurrent writers add up.
      current = SuperPi.Durable.Doc.snapshot_for_update("conversation", conversation_id, "pi.usage") || %{}
      cur_in = Map.get(current, "inputTokens", 0)
      cur_out = Map.get(current, "outputTokens", 0)

      updated = %{
        "inputTokens" => cur_in + in_tok,
        "outputTokens" => cur_out + out_tok,
        "lastTurnInputTokens" => in_tok,
        "lastTurnOutputTokens" => out_tok,
        "updatedAt" => System.system_time(:millisecond)
      }

      SuperPi.Durable.Doc.put_doc("conversation", conversation_id, "pi.usage", updated, seq)
      updated
    end)
    |> case do
      {:ok, updated} when is_map(updated) -> {:ok, usage_totals(updated, in_tok, out_tok)}
      %{} = updated -> {:ok, usage_totals(updated, in_tok, out_tok)}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp usage_totals(updated, in_tok, out_tok) do
    %{
      "input_tokens" => in_tok,
      "output_tokens" => out_tok,
      "total_input_tokens" => updated["inputTokens"],
      "total_output_tokens" => updated["outputTokens"]
    }
  end
end
