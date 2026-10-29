defmodule SuperPi.Extension do
  @moduledoc """
  Unified 12-Hook Extension Pipeline behaviour (`09 - Data Flows and Extension Injection Points.md`).

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

  @callback on_input(input :: String.t(), context()) ::
              :continue | {:transform, String.t(), list()} | :handled

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
              :continue | {:steer, String.t()} | {:handoff, map()}

  @callback on_yield(yield_info :: map(), context()) ::
              :ok

  @callback after_run(run_summary :: map(), context()) ::
              :accept | {:continue, String.t()}

  @optional_callbacks [
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

      defoverridable [
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
    end
  end

  # --- Pipeline Runners ---

  def run_on_input(extensions, input, ctx) do
    Enum.reduce_while(extensions, {:continue, input, []}, fn ext, {:continue, cur_input, cur_media} ->
      case ext.on_input(cur_input, ctx) do
        :continue -> {:cont, {:continue, cur_input, cur_media}}
        {:transform, new_input, new_media} -> {:cont, {:continue, new_input, cur_media ++ new_media}}
        :handled -> {:halt, :handled}
      end
    end)
  end

  def run_before_agent_start(extensions, agent_cfg, ctx) do
    Enum.reduce(extensions, agent_cfg, fn ext, acc ->
      {:ok, next} = ext.before_agent_start(acc, ctx)
      next
    end)
  end

  def run_before_compact(extensions, req, ctx) do
    Enum.reduce_while(extensions, :default, fn ext, _acc ->
      case ext.before_compact(req, ctx) do
        :default -> {:cont, :default}
        {:compacted, summary, data} -> {:halt, {:compacted, summary, data}}
        :cancel -> {:halt, :cancel}
      end
    end)
  end

  def run_before_request(extensions, derived, ctx) do
    Enum.reduce(extensions, derived, fn ext, acc ->
      {:ok, next} = ext.before_request(acc, ctx)
      next
    end)
  end

  def run_before_provider_request(extensions, payload, ctx) do
    Enum.reduce_while(extensions, {:ok, payload}, fn ext, {:ok, acc} ->
      case ext.before_provider_request(acc, ctx) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:abort, reason} -> {:halt, {:abort, reason}}
      end
    end)
  end

  def run_after_response(extensions, msg, ctx) do
    Enum.reduce(extensions, msg, fn ext, acc ->
      {:ok, next} = ext.after_response(acc, ctx)
      next
    end)
  end

  def run_before_tool(extensions, tool_name, args, ctx) do
    Enum.reduce_while(extensions, {:allow, args, []}, fn ext, {:allow, cur_args, overwritten_keys} ->
      case ext.before_tool(tool_name, cur_args, ctx) do
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
    end)
    |> case do
      {:allow, final_args, []} -> {:allow, final_args}
      {:allow, final_args, keys} -> {:allow_overwritten, final_args, keys}
      {:block, reason} -> {:block, reason}
    end
  end

  def run_wrap_tool(extensions, tool_name, args, core_exec_fun, ctx) do
    chain =
      Enum.reverse(extensions)
      |> Enum.reduce(core_exec_fun, fn ext, next_fn ->
        fn current_args -> ext.wrap_tool(tool_name, current_args, next_fn, ctx) end
      end)

    chain.(args)
  end

  def run_after_tool(extensions, tool_name, args, result, ctx) do
    Enum.reduce(extensions, result, fn ext, acc ->
      {:ok, next} = ext.after_tool(tool_name, args, acc, ctx)
      next
    end)
  end

  def run_after_tools(extensions, results, ctx) do
    Enum.reduce_while(extensions, :continue, fn ext, :continue ->
      case ext.after_tools(results, ctx) do
        :continue -> {:cont, :continue}
        other -> {:halt, other}
      end
    end)
  end

  def run_after_run(extensions, summary, ctx) do
    Enum.reduce_while(extensions, :accept, fn ext, :accept ->
      case ext.after_run(summary, ctx) do
        :accept -> {:cont, :accept}
        {:continue, follow_up} -> {:halt, {:continue, follow_up}}
      end
    end)
  end
end
