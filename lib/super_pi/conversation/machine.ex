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
  - `:executing_tools` — Runs tool calls through `before_tool` -> `wrap_tool` -> `SandboxRunner` -> `after_tool`, then `after_tools`; handles mid-batch `:steer` preemption by skipping remaining queued tools in the batch.
  - `:sleeping_backoff` — Pauses turn execution when provider rate-limits/retries occur (`TaskEngine.sleep_until/3`).
  - `:compacting` — Runs `before_compact` or default compaction and records `pi.compaction` with `head_entry_id`.
  - `:settling_run` — Runs `after_run` verification gate; either loops back to `:preparing_request` (`{:continue, prompt}`) or completes the durable `pi.generation` task and returns to `:idle`.
  """

  @behaviour :gen_statem

  alias SuperPi.Durable.{Context, DeferredFlusher, Doc, Storage, TaskEngine}
  alias SuperPi.Env.SandboxRunner
  alias SuperPi.Extension

  defstruct [
    :conversation_id,
    :active_task_id,
    :llm_responder,
    :tool_executor,
    extensions: [],
    pending_tool_calls: [],
    completed_tool_results: [],
    steer_preempted: false,
    last_assistant_message: nil,
    reply_from: nil
  ]

  @impl :gen_statem
  def callback_mode, do: [:handle_event_function, :state_enter]

  # --- Public Client API ---

  def start_link(opts) do
    conv_id = Keyword.fetch!(opts, :conversation_id)
    :gen_statem.start_link(via_tuple(conv_id), __MODULE__, opts, [])
  end

  def via_tuple(conversation_id) do
    {:via, Registry, {SuperPi.Registry, {:conversation_machine, conversation_id}}}
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
  Triggers manual or threshold compaction on the conversation.
  """
  def compact(pid_or_via, opts \\ []) do
    :gen_statem.call(pid_or_via, {:compact, opts}, 30_000)
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

    data = %__MODULE__{
      conversation_id: conv_id,
      extensions: extensions,
      llm_responder: llm_responder,
      tool_executor: tool_executor
    }

    {:ok, :recovering, data, [{:next_event, :internal, :reconcile}]}
  end

  # --- State: :recovering ---

  @impl :gen_statem
  def handle_event(:enter, _old_state, :recovering, data) do
    publish_live_state(data.conversation_id, "recovering")
    :keep_state_and_data
  end

  def handle_event(:internal, :reconcile, :recovering, data) do
    _reconciled = TaskEngine.reconcile_on_open!(data.conversation_id)
    {:next_state, :idle, data}
  end

  # --- State: :idle ---

  def handle_event(:enter, _old_state, :idle, %__MODULE__{} = data) do
    publish_live_state(data.conversation_id, "idle")
    {:keep_state, %__MODULE__{data | active_task_id: nil, steer_preempted: false, pending_tool_calls: [], completed_tool_results: []}}
  end

  def handle_event({:call, from}, :get_state, state, data) do
    {:keep_state_and_data, [{:reply, from, {state, data}}]}
  end

  def handle_event({:call, from}, {:set_extensions, extensions}, _state, %__MODULE__{} = data) do
    {:keep_state, %__MODULE__{data | extensions: extensions}, [{:reply, from, :ok}]}
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

  def handle_event({:call, from}, {:submit, mode, raw_text, _opts}, :idle, %__MODULE__{} = data)
      when mode in [:queue, :steer] do
    ctx = hook_ctx(data)

    case Extension.run_on_input(data.extensions, raw_text, ctx) do
      :handled ->
        {:keep_state_and_data, [{:reply, from, {:ok, :handled_by_extension}}]}

      {:continue, transformed_text, _media} ->
        Storage.append_entry!(data.conversation_id, "pi.message", %{
          "role" => "user",
          "content" => [%{"type" => "text", "text" => transformed_text}]
        })

        {:ok, gen_task} =
          TaskEngine.create_task(data.conversation_id, "pi.generation", %{"prompt" => transformed_text})

        {:ok, running_task} = TaskEngine.start_task(gen_task.id)

        next_data = %__MODULE__{
          data
          | active_task_id: running_task.id,
            reply_from: from,
            steer_preempted: false
        }

        {:next_state, :preparing_request, next_data, [{:next_event, :internal, :prepare}]}
    end
  end

  def handle_event({:call, from}, {:compact, opts}, :idle, %__MODULE__{} = data) do
    {:next_state, :compacting, %__MODULE__{data | reply_from: from}, [{:next_event, :internal, {:run_compaction, opts}}]}
  end

  # --- Queued `:queue` submissions while busy use `:postpone` (`REQ-FSM-03`) ---
  def handle_event({:call, _from}, {:submit, :queue, _text, _opts}, busy_state, _data)
      when busy_state not in [:idle, :recovering] do
    {:keep_state_and_data, [:postpone]}
  end

  # --- Preemptive `:steer` submission while executing tools or streaming (`REQ-FSM-03`) ---
  def handle_event({:call, _from}, {:submit, :steer, text, _opts}, busy_state, %__MODULE__{} = data)
      when busy_state in [:streaming_llm, :executing_tools] do
    Storage.append_entry!(data.conversation_id, "pi.message", %{
      "role" => "user",
      "content" => [%{"type" => "text", "text" => text}],
      "steer" => true
    })

    # Mark steer_preempted so remaining tool calls in the batch are skipped and we re-enter :preparing_request
    {:keep_state, %__MODULE__{data | steer_preempted: true, pending_tool_calls: []}, [:postpone]}
  end

  # Wait for `:steer` if in other transitional states
  def handle_event({:call, _from}, {:submit, :steer, _text, _opts}, _other_state, _data) do
    {:keep_state_and_data, [:postpone]}
  end

  # --- State: :preparing_request ---

  def handle_event(:enter, _old_state, :preparing_request, %__MODULE__{} = data) do
    publish_live_state(data.conversation_id, "preparing_request")
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

    tools = Map.get(mutated_agent, "tools", [])
    Context.ensure_system_state!(data.conversation_id, sections, tools)

    derived = Context.derive(data.conversation_id)
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
        if data.active_task_id do
          TaskEngine.checkpoint_task(data.active_task_id, "streaming_llm", %{"model" => final_payload.model})
        end

        {:next_state, :streaming_llm, data, [{:next_event, :internal, {:invoke_llm, final_payload}}]}

      {:abort, reason} ->
        finish_run_with_error(data, reason)
    end
  end

  # --- State: :streaming_llm ---

  def handle_event(:enter, _old_state, :streaming_llm, %__MODULE__{} = data) do
    publish_live_state(data.conversation_id, "streaming_llm")
    :keep_state_and_data
  end

  def handle_event(:internal, {:invoke_llm, payload}, :streaming_llm, %__MODULE__{} = data) do
    ctx = hook_ctx(data)

    case data.llm_responder.(payload, ctx) do
      {:ok, assistant_msg} ->
        assistant_msg = Extension.run_after_response(data.extensions, assistant_msg, ctx)
        usage = Map.get(assistant_msg, "usage", %{})
        record_usage!(data.conversation_id, usage)

        Storage.append_entry!(data.conversation_id, "pi.message", %{
          "role" => "assistant",
          "content" => Map.get(assistant_msg, "content", []),
          "usage" => usage
        })

        tool_calls =
          assistant_msg
          |> Map.get("content", [])
          |> Enum.filter(fn b -> Map.get(b, "type") == "tool_call" end)

        next_data = %__MODULE__{data | last_assistant_message: assistant_msg}

        cond do
          next_data.steer_preempted ->
            {:next_state, :preparing_request, %__MODULE__{next_data | steer_preempted: false}, [{:next_event, :internal, :prepare}]}

          tool_calls != [] ->
            if next_data.active_task_id do
              TaskEngine.checkpoint_task(next_data.active_task_id, "executing_tools", %{
                "toolCount" => length(tool_calls)
              })
            end

            {:next_state, :executing_tools,
             %__MODULE__{next_data | pending_tool_calls: tool_calls, completed_tool_results: []},
             [{:next_event, :internal, :next_tool}]}

          true ->
            {:next_state, :settling_run, next_data, [{:next_event, :internal, :verify_run}]}
        end

      {:retry_after, delay_ms} ->
        wake_at = DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)

        if data.active_task_id do
          TaskEngine.sleep_until(data.active_task_id, wake_at, %{"phase" => "backoff"})
        end

        {:next_state, :sleeping_backoff, data, [{:state_timeout, delay_ms, :wake_from_backoff}]}

      {:error, reason} ->
        finish_run_with_error(data, reason)
    end
  end

  # --- State: :sleeping_backoff ---

  def handle_event(:enter, _old_state, :sleeping_backoff, %__MODULE__{} = data) do
    publish_live_state(data.conversation_id, "sleeping_backoff")
    :keep_state_and_data
  end

  def handle_event(:state_timeout, :wake_from_backoff, :sleeping_backoff, %__MODULE__{} = data) do
    if data.active_task_id do
      TaskEngine.wake_sleeping_task(data.active_task_id)
      TaskEngine.start_task(data.active_task_id)
    end

    {:next_state, :preparing_request, data, [{:next_event, :internal, :prepare}]}
  end

  # --- State: :executing_tools ---

  def handle_event(:enter, _old_state, :executing_tools, %__MODULE__{} = data) do
    publish_live_state(data.conversation_id, "executing_tools")
    :keep_state_and_data
  end

  def handle_event(:internal, :next_tool, :executing_tools, %__MODULE__{steer_preempted: true} = data) do
    # Steer preemption arrived mid-batch: skip remaining tools and immediately start next turn
    {:next_state, :preparing_request, %__MODULE__{data | steer_preempted: false, pending_tool_calls: []},
     [{:next_event, :internal, :prepare}]}
  end

  def handle_event(:internal, :next_tool, :executing_tools, %__MODULE__{pending_tool_calls: []} = data) do
    ctx = hook_ctx(data)
    results = Enum.reverse(data.completed_tool_results)

    has_terminate? =
      Enum.any?(results, fn res ->
        get_in(res, ["control", "terminate"]) == true
      end)

    if has_terminate? do
      {:next_state, :settling_run, data, [{:next_event, :internal, :settle}]}
    else
      case Extension.run_after_tools(data.extensions, results, ctx) do
        {:steer, steer_msg} ->
          Storage.append_entry!(data.conversation_id, "pi.message", %{
            "role" => "user",
            "content" => [%{"type" => "text", "text" => steer_msg}]
          })

          {:next_state, :preparing_request, data, [{:next_event, :internal, :prepare}]}

        {:handoff, handoff_cfg} ->
          Storage.configure_agent!(data.conversation_id, handoff_cfg)
          {:next_state, :preparing_request, data, [{:next_event, :internal, :prepare}]}

        :terminate ->
          {:next_state, :settling_run, data, [{:next_event, :internal, :settle}]}

        :continue ->
          {:next_state, :preparing_request, data, [{:next_event, :internal, :prepare}]}
      end
    end
  end

  def handle_event(:internal, :next_tool, :executing_tools, %__MODULE__{pending_tool_calls: [tc | rest]} = data) do
    ctx = hook_ctx(data)
    tool_name = Map.get(tc, "name", "unknown")
    tool_id = Map.get(tc, "id", "call_0")
    raw_args = Map.get(tc, "arguments", %{})

    tool_result =
      case Extension.run_before_tool(data.extensions, tool_name, raw_args, ctx) do
        {:block, reason} ->
          publish_stream_event(data.conversation_id, %{
            "type" => "tool_blocked",
            "tool_call_id" => tool_id,
            "name" => tool_name,
            "reason" => reason
          })

          %{
            "tool_call_id" => tool_id,
            "name" => tool_name,
            "is_error" => true,
            "output" => "Blocked by extension: #{reason}",
            "structured_output" => nil,
            "details" => %{"blocked" => true}
          }

        decision when elem(decision, 0) in [:allow, :allow_overwritten] ->
          {validated_args, overwritten_keys} =
            case decision do
              {:allow, a} -> {a, []}
              {:allow_overwritten, a, keys} -> {a, keys}
            end

          publish_stream_event(data.conversation_id, %{
            "type" => "tool_started",
            "tool_call_id" => tool_id,
            "name" => tool_name,
            "arguments" => validated_args,
            "overwritten_keys" => overwritten_keys
          })

          core_fn = fn exec_args ->
            case SandboxRunner.run_isolated(fn -> data.tool_executor.(tool_name, exec_args, ctx) end) do
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

          wrapped_res = Extension.run_wrap_tool(data.extensions, tool_name, validated_args, core_fn, ctx)
          final_res = Extension.run_after_tool(data.extensions, tool_name, validated_args, wrapped_res, ctx)

          final_res =
            if overwritten_keys != [] do
              notice = "[Hook Notice: PreToolUse rewrote tool arguments for keys: #{Enum.join(overwritten_keys, ", ")}]\n"
              Map.update(final_res, "output", notice, &(notice <> to_string(&1)))
            else
              final_res
            end

          publish_stream_event(data.conversation_id, %{
            "type" => "tool_completed",
            "tool_call_id" => tool_id,
            "name" => tool_name,
            "is_error" => Map.get(final_res, "is_error", false),
            "output" => Map.get(final_res, "output", "")
          })

          final_res
      end

    # Persist tool result as a durable entry (`pi.message` role `tool` with 3-channel fields)
    Storage.append_entry!(data.conversation_id, "pi.message", %{
      "role" => "tool",
      "tool_call_id" => tool_id,
      "name" => tool_name,
      "is_error" => tool_result["is_error"],
      "content" => tool_result["output"],
      "structured_output" => tool_result["structured_output"],
      "details" => tool_result["details"]
    })

    # Check if tool returned a control action (`add_tools`, `handoff`, `terminate`)
    apply_tool_control_directive(data.conversation_id, Map.get(tool_result, "control"))

    next_data = %__MODULE__{
      data
      | pending_tool_calls: rest,
        completed_tool_results: [tool_result | data.completed_tool_results]
    }

    {:keep_state, next_data, [{:next_event, :internal, :next_tool}]}
  end

  # --- State: :compacting ---

  def handle_event(:enter, _old_state, :compacting, %__MODULE__{} = data) do
    publish_live_state(data.conversation_id, "compacting")
    :keep_state_and_data
  end

  def handle_event(:internal, {:run_compaction, opts}, :compacting, %__MODULE__{} = data) do
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
          summary_text = Keyword.get(opts, :summary, "Compacted #{length(visible)} entries.")
          head_id = find_compaction_cutoff_id(visible)

          entry =
            Storage.append_entry!(
              data.conversation_id,
              "pi.compaction",
              %{"summary" => summary_text},
              head_entry_id: head_id
            )

          {:ok, %{entry_id: entry.id, summary: summary_text, head_entry_id: head_id}}
      end

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
    publish_live_state(data.conversation_id, "settling_run")
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
        if data.active_task_id do
          TaskEngine.complete_task(data.active_task_id, %{
            "assistantMessage" => data.last_assistant_message
          })
        end

        actions =
          if data.reply_from do
            [{:reply, data.reply_from, {:ok, data.last_assistant_message}}]
          else
            []
          end

        {:next_state, :idle, %__MODULE__{data | active_task_id: nil, reply_from: nil}, actions}
    end
  end

  # --- Helpers ---

  defp finish_run_with_error(%__MODULE__{} = data, reason) do
    if data.active_task_id do
      TaskEngine.fail_task(data.active_task_id, %{"error" => inspect(reason)})
    end

    actions =
      if data.reply_from do
        [{:reply, data.reply_from, {:error, reason}}]
      else
        []
      end

    {:next_state, :idle, %__MODULE__{data | active_task_id: nil, reply_from: nil}, actions}
  end

  defp apply_tool_control_directive(_conv_id, nil), do: :ok

  defp apply_tool_control_directive(conv_id, %{"add_tools" => new_tools}) when is_list(new_tools) do
    agent = Doc.snapshot("conversation", conv_id, "pi.agent") || %{}
    existing = Map.get(agent, "tools", [])
    merged = Enum.uniq_by(existing ++ new_tools, &Map.get(&1, "name"))
    Storage.configure_agent!(conv_id, %{"tools" => merged})
  end

  defp apply_tool_control_directive(conv_id, %{"handoff" => new_agent_cfg}) when is_map(new_agent_cfg) do
    Storage.configure_agent!(conv_id, new_agent_cfg)
  end

  defp apply_tool_control_directive(_conv_id, _other), do: :ok

  defp find_compaction_cutoff_id([]), do: nil

  defp find_compaction_cutoff_id(visible) do
    List.last(visible).id
  end

  defp publish_live_state(conv_id, status) do
    DeferredFlusher.stage_deferred("conversation", conv_id, "pi.live", %{
      "status" => status,
      "updatedAt" => System.system_time(:millisecond)
    })

    Phoenix.PubSub.broadcast(
      SuperPi.PubSub,
      "conversation:#{conv_id}",
      {:conversation_state, conv_id, status}
    )

    publish_stream_event(conv_id, %{"type" => "state_changed", "status" => status})
  end

  defp publish_stream_event(conv_id, event_map) when is_map(event_map) do
    enriched =
      event_map
      |> Map.put_new("conversation_id", conv_id)
      |> Map.put_new("timestamp_ms", System.system_time(:millisecond))

    Phoenix.PubSub.broadcast(
      SuperPi.PubSub,
      "conversation:#{conv_id}",
      {:conversation_event, conv_id, enriched}
    )
  end

  defp hook_ctx(data) do
    %{
      conversation_id: data.conversation_id,
      active_task_id: data.active_task_id,
      emit_event: fn ev -> publish_stream_event(data.conversation_id, ev) end
    }
  end

  defp default_llm_responder(payload, ctx) do
    model = to_string(Map.get(payload, :model, "claude-sonnet-4-5"))
    conv_id = Map.get(ctx, :conversation_id)

    effective_model =
      cond do
        String.starts_with?(model, "gemini-") ->
          model

        String.starts_with?(model, "google/") ->
          String.replace_prefix(model, "google/", "")

        SuperPi.AI.GeminiClient.configured?() and
            (SuperPi.Harness.harness?(model) or String.starts_with?(model, "super-pi-") or model == "default") ->
          case model do
            m when m in ["super-pi-planner", "planner"] -> "gemini-3.1-pro-preview"
            m when m in ["super-pi-fast", "fast"] -> "gemini-3-flash-preview"
            _ -> "gemini-3-flash-preview"
          end

        true ->
          model
      end

    if String.starts_with?(effective_model, "gemini-") and SuperPi.AI.GeminiClient.configured?() do
      payload = Map.put(payload, :model, effective_model)

      SuperPi.AI.GeminiClient.generate(payload,
        on_delta: fn
          {:text_delta, %{index: idx, delta: delta}} ->
            publish_stream_event(conv_id, %{"type" => "text_delta", "index" => idx, "delta" => delta})

          {:text_delta, idx, delta} ->
            publish_stream_event(conv_id, %{"type" => "text_delta", "index" => idx, "delta" => delta})

          {:thinking_delta, %{index: idx, delta: delta}} ->
            publish_stream_event(conv_id, %{"type" => "thinking_delta", "index" => idx, "delta" => delta})

          {:thinking_delta, idx, delta} ->
            publish_stream_event(conv_id, %{"type" => "thinking_delta", "index" => idx, "delta" => delta})

          {:toolcall_delta, %{index: idx, raw_json_delta: delta, partial_args: partial_args}} ->
            publish_stream_event(conv_id, %{
              "type" => "toolcall_delta",
              "index" => idx,
              "delta" => delta,
              "partial_args" => partial_args
            })

          {:toolcall_delta, idx, delta, partial_args} ->
            publish_stream_event(conv_id, %{
              "type" => "toolcall_delta",
              "index" => idx,
              "delta" => delta,
              "partial_args" => partial_args
            })

          _ ->
            :ok
        end
      )
    else
      last_user =
        payload.messages
        |> Enum.reverse()
        |> Enum.find(fn m -> m["role"] == "user" end)

      user_text =
        case last_user do
          %{"content" => [%{"text" => t} | _]} -> t
          %{"content" => t} when is_binary(t) -> t
          _ -> ""
        end

      reply_text = "Echo: #{user_text}"

      if conv_id do
        publish_stream_event(conv_id, %{"type" => "text_delta", "index" => 0, "delta" => reply_text})
      end

      {:ok,
       %{
         "role" => "assistant",
         "content" => [%{"type" => "text", "text" => reply_text}],
         "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
       }}
    end
  end

  defp default_tool_executor(tool_name, args, ctx) do
    SuperPi.Tools.execute(tool_name, args, ctx)
  end

  defp record_usage!(conversation_id, usage) when is_map(usage) do
    in_tok = Map.get(usage, "input_tokens", 0) || Map.get(usage, :input_tokens, 0) || 0
    out_tok = Map.get(usage, "output_tokens", 0) || Map.get(usage, :output_tokens, 0) || 0

    if in_tok > 0 or out_tok > 0 do
      current = SuperPi.Durable.Doc.snapshot("conversation", conversation_id, "pi.usage") || %{}
      cur_in = Map.get(current, "inputTokens", 0)
      cur_out = Map.get(current, "outputTokens", 0)

      updated = %{
        "inputTokens" => cur_in + in_tok,
        "outputTokens" => cur_out + out_tok,
        "lastTurnInputTokens" => in_tok,
        "lastTurnOutputTokens" => out_tok,
        "updatedAt" => System.system_time(:millisecond)
      }

      Storage.commit(fn seq ->
        SuperPi.Durable.Doc.put_doc("conversation", conversation_id, "pi.usage", updated, seq)
      end)
    end
  rescue
    _ -> :ok
  end
end
