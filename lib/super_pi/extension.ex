defmodule SuperPi.Extension do
  @moduledoc """
  Unified 12-Hook Extension Pipeline behaviour (`09 - Data Flows and Extension Injection Points.md`).

  `configure_agent/2` supplies durable defaults. `before_agent_start/2` transforms durable
  configuration; `prepare_request/2` runs afterwards on a separate, never-persisted copy.
  Both return `{:ok, agent}`. A request hook cannot change the persistence of another hook.
  Request hooks follow composition order (for example filter tools before customizing prompts).

  `lifecycle_effects/0` defaults to `[:unknown]`. Undeclared or mutating extensions are inactive
  in plan mode. Declare `[]` for passive hooks, or `[:audit]` for internal transcript logging only.
  Tool effects are separate: tool handlers still pass the permission gate.
  `tools/1`, `tool_policy/3`, and `execute_tool/3` declare and implement plugin-owned tools.
  `commands/0` reserves slash commands ahead of fallback input handlers.
  `session_modes/2`, `select_mode/3`, and `mode_state/2` expose modes without coupling clients
  to a particular plugin. Mode providers persist their configuration in `configure_agent/2`.

  ## Tool and mode declarations

  `tools(agent)` is a pure declaration callback returning specs with `name`, `parameters` and
  `effects`. An optional `capabilities` list adds workspace requirements (`fs`, `exec`, `net`,
  `artifacts`). `administrative: true` (a string key on the spec) identifies policy-changing
  tools that remain available in Plan and outside profile filters, subject to explicit deny rules.
  Administrative handlers run outside the sandbox timeout so human approval can wait safely.
  Only server-composed declarations confer this authority; client-supplied metadata cannot.
  `tool_policy(name, args, agent)` returns `{:ok, policy}` or `{:error, reason}`. The policy may
  supply atom keys `:command`, `:argv` and `:paths` for standard approval and workspace checks.
  `execute_tool(name, args, ctx)` owns dispatch. Declarations must not invoke tool/effect lookup
  recursively. Existing `before_agent_start`/`wrap_tool` providers remain supported.

  `session_modes(agent, ctx)` returns `nil` when unsupported, otherwise a map with `currentModeId`
  and `availableModes`. Each mode includes `id`, `name`, `description` and its `executionMode`.
  `select_mode/3` returns `{:ok, agent}` or `{:error, reason}`. `mode_state/2` returns only the
  provider-owned selection state to restore; `configure_agent/2` must preserve restored state.
  `commands/0` returns names without `/`; a single owner runs before fallback input handlers.

  Every callback is optional; modules that `use SuperPi.Extension` inherit pass-through default
  implementations and can override only the hooks they need.

  ## The 12 Canonical Extension Hooks
  1. `on_input/2` — Intercepts raw user text before turn creation (`:continue`, `{:transform, text, media}`, `:handled`).
  2. `before_agent_start/2` — Mutates initial system prompt sections and active tool definitions before the run starts.
  3. `before_compact/2` — Overrides or customizes context compaction (`:default`, `{:compacted, summary, data}`, `:cancel`).
  4. `before_request/2` — Inspects/filters derived context messages in-memory right before provider serialization.
  5. `before_provider_request/2` — Inspects/mutates the raw provider HTTP/JSON payload or aborts the call.
  6. `after_response/2` — Inspects the completed assistant response and token usage before tool dispatch.
  7. `before_tool/3` — Permission gate and input validator before a tool executes (`:allow`, `{:block, reason}`, `{:mutate_input, map}`).
  8. `wrap_tool/4` — Higher-order middleware around tool execution (`next.(args)`).
  9. `after_tool/4` — Post-processes 3-channel tool output (`output`, `structured_output`, `details`) before recording `pi.event`.
  10. `after_tools/3` — Runs after a parallel tool batch settles (`:continue`, `{:steer, msg}`, `{:handoff, agent}`).
  11. `on_yield/3` — Intercepts child task or external yield waits.
  12. `after_run/2` — Verification and continuation gate when the assistant stops calling tools (`:accept` or `{:continue, follow_up_prompt}`).
  """

  @type context :: map()

  @callback configure_agent(map(), context()) :: map()
  @callback lifecycle_effects() :: [atom()]
  @callback prepare_request(map(), context()) :: {:ok, map()}
  @callback tools(map()) :: [map()]
  @callback tool_policy(String.t(), map(), map()) :: {:ok, map()} | {:error, String.t()}
  @callback execute_tool(String.t(), map(), context()) :: map() | :unhandled
  @callback commands() :: [String.t()]
  @callback session_modes(map(), context()) :: map() | nil
  @callback select_mode(map(), String.t(), context()) ::
              {:ok, map()} | {:error, String.t()} | :unsupported
  @callback mode_state(map(), context()) :: map()

  @callback on_input(input :: String.t(), context()) ::
              :continue | {:transform, String.t(), list()} | :handled | {:error, String.t()}

  @callback before_agent_start(agent_config :: map(), context()) ::
              {:ok, map()}

  @callback before_compact(compaction_req :: map(), context()) ::
              :default | {:compacted, String.t(), map()} | :cancel

  @callback before_request(derived_context :: map(), context()) ::
              {:ok, map()}

  @callback before_provider_request(provider_payload :: map(), context()) ::
              {:ok, map()} | {:abort, term()}

  @callback after_response(assistant_msg :: map(), context()) ::
              {:ok, map()}

  @callback before_tool(tool_name :: String.t(), args :: map(), context()) ::
              :allow
              | {:block, String.t()}
              | {:mutate_input, map()}
              | {:overwrite, map()}

  @callback wrap_tool(tool_name :: String.t(), args :: map(), next :: (map() -> map()), context()) ::
              map()

  @callback after_tool(tool_name :: String.t(), args :: map(), result :: map(), context()) ::
              {:ok, map()}

  @callback after_tools(batch_results :: list(map()), context()) ::
              :continue | {:steer, String.t()} | {:handoff, map()} | :terminate

  @callback on_yield(yield_info :: map(), context()) ::
              :ok

  @callback after_run(run_summary :: map(), context()) ::
              :accept | {:continue, String.t()}

  @optional_callbacks [
    configure_agent: 2,
    lifecycle_effects: 0,
    prepare_request: 2,
    tools: 1,
    tool_policy: 3,
    execute_tool: 3,
    commands: 0,
    session_modes: 2,
    select_mode: 3,
    mode_state: 2,
    on_input: 2,
    before_agent_start: 2,
    before_compact: 2,
    before_request: 2,
    before_provider_request: 2,
    after_response: 2,
    before_tool: 3,
    wrap_tool: 4,
    after_tool: 4,
    after_tools: 2,
    on_yield: 2,
    after_run: 2
  ]

  defmacro __using__(_opts) do
    quote do
      @behaviour SuperPi.Extension

      @impl true
      def configure_agent(agent, _ctx), do: agent

      @impl true
      def lifecycle_effects, do: [:unknown]

      @impl true
      def prepare_request(agent, _ctx), do: {:ok, agent}
      @impl true
      def tools(_agent), do: []
      @impl true
      def tool_policy(_name, _args, _agent), do: {:ok, %{}}
      @impl true
      def execute_tool(_name, _args, _ctx), do: :unhandled
      @impl true
      def commands, do: []
      @impl true
      def session_modes(_agent, _ctx), do: nil
      @impl true
      def select_mode(_agent, _mode, _ctx), do: :unsupported
      @impl true
      def mode_state(_agent, _ctx), do: %{}

      @impl true
      def on_input(_input, _ctx), do: :continue

      @impl true
      def before_agent_start(agent_cfg, _ctx), do: {:ok, agent_cfg}

      @impl true
      def before_compact(_req, _ctx), do: :default

      @impl true
      def before_request(derived, _ctx), do: {:ok, derived}

      @impl true
      def before_provider_request(payload, _ctx), do: {:ok, payload}

      @impl true
      def after_response(msg, _ctx), do: {:ok, msg}

      @impl true
      def before_tool(_name, _args, _ctx), do: :allow

      @impl true
      def wrap_tool(_name, args, next, _ctx), do: next.(args)

      @impl true
      def after_tool(_name, _args, result, _ctx), do: {:ok, result}

      @impl true
      def after_tools(_results, _ctx), do: :continue

      @impl true
      def on_yield(_info, _ctx), do: :ok

      @impl true
      def after_run(_summary, _ctx), do: :accept

      defoverridable configure_agent: 2,
                     lifecycle_effects: 0,
                     prepare_request: 2,
                     tools: 1,
                     tool_policy: 3,
                     execute_tool: 3,
                     commands: 0,
                     session_modes: 2,
                     select_mode: 3,
                     mode_state: 2,
                     on_input: 2,
                     before_agent_start: 2,
                     before_compact: 2,
                     before_request: 2,
                     before_provider_request: 2,
                     after_response: 2,
                     before_tool: 3,
                     wrap_tool: 4,
                     after_tool: 4,
                     after_tools: 2,
                     on_yield: 2,
                     after_run: 2
    end
  end

  # --- Pipeline Runners ---

  def configure_agent(extensions, agent, ctx \\ %{}) do
    agent =
      Enum.reduce(extensions, agent, fn ext, acc ->
        {mod, _} = unpack_ext(ext)

        if function_exported?(mod, :configure_agent, 2),
          do: mod.configure_agent(acc, ext_ctx(ext, ctx)),
          else: acc
      end)

    providers =
      for ext <- extensions,
          {mod, _} = unpack_ext(ext),
          function_exported?(mod, :session_modes, 2),
          mod.session_modes(agent, ext_ctx(ext, ctx)) != nil,
          do: Atom.to_string(mod)

    if length(providers) > 1,
      do: raise(ArgumentError, "A harness must compose only one session-mode provider")

    agent
    |> Map.put("modeProviders", providers)
    |> then(&SuperPi.PluginTools.declare(extensions, &1))
  end

  # Lifecycle effects bypass the tool permission gate, so disable mutating hooks in read-only modes.
  def active(extensions, agent) do
    if agent["executionMode"] == "plan" do
      Enum.reject(extensions, fn ext ->
        {mod, _} = unpack_ext(ext)

        not function_exported?(mod, :lifecycle_effects, 0) or
          not Enum.all?(mod.lifecycle_effects(), &(&1 in [:read, :net_read, :audit]))
      end)
    else
      extensions
    end
  end

  defp unpack_ext({mod, opts}) when is_atom(mod) do
    Code.ensure_loaded(mod)
    {mod, opts}
  end

  defp unpack_ext(mod) when is_atom(mod) do
    Code.ensure_loaded(mod)
    {mod, []}
  end

  defp unpack_ext(other), do: {other, []}

  defp ext_ctx({_mod, opts}, ctx) do
    Map.put(ctx, :config, opts)
  end

  defp ext_ctx(mod, ctx) when is_atom(mod) do
    Map.put(ctx, :config, [])
  end

  def run_on_input(extensions, input, ctx) do
    command =
      input
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> hd()
      |> String.trim_leading("/")

    {owners, rest} =
      Enum.split_with(extensions, fn ext ->
        {mod, _} = unpack_ext(ext)

        String.starts_with?(String.trim(input), "/") and function_exported?(mod, :commands, 0) and
          command in mod.commands()
      end)

    if length(owners) > 1, do: raise(ArgumentError, "Multiple plugins claim /#{command}")
    extensions = owners ++ rest

    Enum.reduce_while(extensions, {:continue, input, []}, fn ext,
                                                             {:continue, cur_input, cur_media} ->
      {mod, _opts} = unpack_ext(ext)
      mod_ctx = ext_ctx(ext, ctx)

      if function_exported?(mod, :on_input, 2) do
        case mod.on_input(cur_input, mod_ctx) do
          :continue ->
            {:cont, {:continue, cur_input, cur_media}}

          {:transform, new_input, new_media} ->
            {:cont, {:continue, new_input, cur_media ++ new_media}}

          :handled ->
            {:halt, :handled}

          {:error, message} ->
            {:halt, {:error, message}}
        end
      else
        {:cont, {:continue, cur_input, cur_media}}
      end
    end)
  end

  def run_before_agent_start(extensions, agent_cfg, ctx) do
    extensions |> run_agent_start(agent_cfg, ctx) |> elem(1)
  end

  @doc "Runs all durable hooks, then all request-only hooks. Persistence never depends on a previous result."
  def run_agent_start(extensions, agent_cfg, ctx) do
    agent_cfg = SuperPi.PluginTools.declare(extensions, agent_cfg)
    stored = run_agent_hook(extensions, :before_agent_start, agent_cfg, ctx)
    request = run_agent_hook(extensions, :prepare_request, stored, ctx)
    {stored, request}
  end

  defp run_agent_hook(extensions, hook, agent, ctx) do
    Enum.reduce(extensions, agent, fn ext, acc ->
      {mod, _} = unpack_ext(ext)

      if function_exported?(mod, hook, 2) do
        case apply(mod, hook, [acc, ext_ctx(ext, ctx)]) do
          {:ok, next} when is_map(next) ->
            next

          other ->
            raise ArgumentError,
                  "#{inspect(mod)}.#{hook}/2 must return {:ok, map}, got #{inspect(other)}; use prepare_request/2 for request-only changes"
        end
      else
        acc
      end
    end)
  end

  def run_before_compact(extensions, req, ctx) do
    Enum.reduce_while(extensions, :default, fn ext, _acc ->
      {mod, _opts} = unpack_ext(ext)
      mod_ctx = ext_ctx(ext, ctx)

      if function_exported?(mod, :before_compact, 2) do
        case mod.before_compact(req, mod_ctx) do
          :default -> {:cont, :default}
          {:compacted, summary, data} -> {:halt, {:compacted, summary, data}}
          :cancel -> {:halt, :cancel}
        end
      else
        {:cont, :default}
      end
    end)
  end

  def run_before_request(extensions, derived, ctx) do
    Enum.reduce(extensions, derived, fn ext, acc ->
      {mod, _opts} = unpack_ext(ext)
      mod_ctx = ext_ctx(ext, ctx)

      if function_exported?(mod, :before_request, 2) do
        case mod.before_request(acc, mod_ctx) do
          {:ok, next} -> next
          other -> other
        end
      else
        acc
      end
    end)
  end

  def run_before_provider_request(extensions, payload, ctx) do
    Enum.reduce_while(extensions, {:ok, payload}, fn ext, {:ok, acc} ->
      {mod, _opts} = unpack_ext(ext)
      mod_ctx = ext_ctx(ext, ctx)

      if function_exported?(mod, :before_provider_request, 2) do
        case mod.before_provider_request(acc, mod_ctx) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:abort, reason} -> {:halt, {:abort, reason}}
        end
      else
        {:cont, {:ok, acc}}
      end
    end)
  end

  def run_after_response(extensions, msg, ctx) do
    Enum.reduce(extensions, msg, fn ext, acc ->
      {mod, _opts} = unpack_ext(ext)
      mod_ctx = ext_ctx(ext, ctx)

      if function_exported?(mod, :after_response, 2) do
        case mod.after_response(acc, mod_ctx) do
          {:ok, next} -> next
          other -> other
        end
      else
        acc
      end
    end)
  end

  def run_before_tool(extensions, tool_name, args, ctx) do
    Enum.reduce_while(extensions, {:allow, args, []}, fn ext,
                                                         {:allow, cur_args, overwritten_keys} ->
      {mod, _opts} = unpack_ext(ext)
      mod_ctx = ext_ctx(ext, ctx)

      if function_exported?(mod, :before_tool, 3) do
        case mod.before_tool(tool_name, cur_args, mod_ctx) do
          :allow ->
            {:cont, {:allow, cur_args, overwritten_keys}}

          {:mutate_input, new_args} ->
            {:cont, {:allow, new_args, overwritten_keys}}

          {:overwrite, patch_map} when is_map(patch_map) ->
            changed =
              patch_map
              |> Enum.filter(fn {k, v} -> Map.get(cur_args, k) != v end)
              |> Enum.map(fn {k, _v} -> to_string(k) end)

            merged = Map.merge(cur_args, patch_map)
            {:cont, {:allow, merged, Enum.uniq(overwritten_keys ++ changed)}}

          {:block, reason} ->
            {:halt, {:block, reason}}
        end
      else
        {:cont, {:allow, cur_args, overwritten_keys}}
      end
    end)
    |> case do
      {:allow, final_args, []} -> {:allow, final_args}
      {:allow, final_args, keys} -> {:allow_overwritten, final_args, keys}
      {:block, reason} -> {:block, reason}
    end
  end

  def run_wrap_tool(extensions, tool_name, args, core_exec_fun, ctx) do
    original = core_exec_fun

    core_exec_fun = fn args ->
      if SuperPi.PluginTools.administrative?(tool_name, SuperPi.PluginTools.agent(ctx)),
        do: SuperPi.PluginTools.execute(tool_name, args, ctx),
        else: original.(args)
    end

    chain =
      Enum.reverse(extensions)
      |> Enum.reduce(core_exec_fun, fn ext, next_fn ->
        {mod, _opts} = unpack_ext(ext)
        mod_ctx = ext_ctx(ext, ctx)

        if function_exported?(mod, :wrap_tool, 4) do
          fn current_args -> mod.wrap_tool(tool_name, current_args, next_fn, mod_ctx) end
        else
          next_fn
        end
      end)

    chain.(args)
  end

  def run_after_tool(extensions, tool_name, args, result, ctx) do
    Enum.reduce(extensions, result, fn ext, acc ->
      {mod, _opts} = unpack_ext(ext)
      mod_ctx = ext_ctx(ext, ctx)

      if function_exported?(mod, :after_tool, 4) do
        case mod.after_tool(tool_name, args, acc, mod_ctx) do
          {:ok, next} -> next
          other -> other
        end
      else
        acc
      end
    end)
  end

  def run_after_tools(extensions, results, ctx) do
    Enum.reduce_while(extensions, :continue, fn ext, :continue ->
      {mod, _opts} = unpack_ext(ext)
      mod_ctx = ext_ctx(ext, ctx)

      if function_exported?(mod, :after_tools, 2) do
        case mod.after_tools(results, mod_ctx) do
          :continue -> {:cont, :continue}
          other -> {:halt, other}
        end
      else
        {:cont, :continue}
      end
    end)
  end

  def run_after_run(extensions, summary, ctx) do
    Enum.reduce_while(extensions, :accept, fn ext, :accept ->
      {mod, _opts} = unpack_ext(ext)
      mod_ctx = ext_ctx(ext, ctx)

      if function_exported?(mod, :after_run, 2) do
        case mod.after_run(summary, mod_ctx) do
          :accept -> {:cont, :accept}
          {:continue, follow_up} -> {:halt, {:continue, follow_up}}
        end
      else
        {:cont, :accept}
      end
    end)
  end
end
