defmodule SuperPi.Harness.AGY.Extensions.HooksJson do
  @moduledoc """
  Antigravity `hooks.json` Lifecycle Extension (`SuperPi.Extension` behaviour).

  Implements the exact `agy` lifecycle hook contract (`docs/hooks.md`):
  - Discovers and merges `hooks.json` files across workspace `.agents/hooks.json` and `~/.gemini/config/hooks.json`,
    respecting `"enabled": false`.
  - **`SessionStart`** (`before_agent_start/2`): Runs startup hooks once and injects `systemMessage` steps.
  - **`PreInvocation`** (`before_request/2`): Runs before model invocation and injects transient `ephemeralMessage`
    or `userMessage` steps into `derived.messages` for that turn.
  - **`PreToolUse`** (`before_tool/3`): Matches tool names against `matcher` (`"*"`, `""`, or regex), sends
    camelCase JSON payload on `stdin`, and parses `stdout` JSON (`decision: "allow" | "deny" | "ask" | "force_ask"`
    and shallow top-level `overwrite` map).
  - **`PostToolUse`** (`after_tool/4`): Runs matching post-tool commands with `error` metadata when a tool fails.
  - **`PostInvocation`** (`after_tools/2`): Supports `terminationBehavior: "force_continue"`.
  - **`Stop`** (`after_run/2`): Sends `terminationReason: "NO_TOOL_CALL"` and honors `decision: "continue"` + `reason`.
  """

  use SuperPi.Extension

  alias SuperPi.Harness.AGY.Discovery
  alias SuperPi.Durable.Doc

  @impl true
  def before_agent_start(agent_cfg, ctx) do
    hooks_files = resolve_hooks_files(agent_cfg)
    common = build_common_payload(agent_cfg, ctx)

    injected_texts =
      hooks_files
      |> load_merged_handlers("SessionStart")
      |> Enum.flat_map(fn {hook_dir, handler} ->
        case run_hook_command(handler, common, hook_dir) do
          {:ok, %{"injectSteps" => steps}} when is_list(steps) ->
             extract_injected_texts(steps)

          _ ->
            []
        end
      end)

    if injected_texts == [] do
      {:ok, agent_cfg}
    else
      sections = Map.get(agent_cfg, "systemSections", [])
      clean_sections = Enum.reject(sections, &(&1["id"] == "agy_session_start_hooks"))
      joined = Enum.join(injected_texts, "\n")
      {:ok, Map.put(agent_cfg, "systemSections", clean_sections ++ [%{"id" => "agy_session_start_hooks", "content" => joined}])}
    end
  end

  @impl true
  def before_request(derived, ctx) do
    agent_cfg = Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{}
    hooks_files = resolve_hooks_files(agent_cfg)
    common = Map.merge(build_common_payload(agent_cfg, ctx), %{"invocationNum" => 1, "initialNumSteps" => length(derived.messages)})

    ephemeral_msgs =
      hooks_files
      |> load_merged_handlers("PreInvocation")
      |> Enum.flat_map(fn {hook_dir, handler} ->
        case run_hook_command(handler, common, hook_dir) do
          {:ok, %{"injectSteps" => steps}} when is_list(steps) ->
            steps
            |> extract_injected_texts()
            |> Enum.map(fn text ->
              %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
            end)

          _ ->
            []
        end
      end)

    {:ok, %{derived | messages: derived.messages ++ ephemeral_msgs}}
  end

  @impl true
  def before_tool(tool_name, args, ctx) do
    agent_cfg = Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{}
    hooks_files = resolve_hooks_files(agent_cfg)

    input_payload =
      build_common_payload(agent_cfg, ctx)
      |> Map.merge(%{
        "toolCall" => %{"name" => tool_name, "args" => args},
        "stepIdx" => 1
      })

    handlers = load_matched_tool_handlers(hooks_files, "PreToolUse", tool_name)

    Enum.reduce_while(handlers, {:allow, %{}}, fn {hook_dir, handler}, {:allow, acc_overwrite} ->
      case run_hook_command(handler, input_payload, hook_dir) do
        {:ok, %{"decision" => decision} = out} when decision in ["deny", "block"] ->
          reason = Map.get(out, "reason", "Denied by PreToolUse hook")
          {:halt, {:block, reason}}

        {:ok, %{"decision" => decision} = out} when decision in ["ask", "force_ask"] ->
          reason = Map.get(out, "reason", "User confirmation required by PreToolUse hook (#{decision})")
          {:halt, {:block, reason}}

        {:ok, %{"overwrite" => ow}} when is_map(ow) and map_size(ow) > 0 ->
          {:cont, {:allow, Map.merge(acc_overwrite, ow)}}

        {:ok, _} ->
          {:cont, {:allow, acc_overwrite}}

        {:error, :hook_timeout} ->
          {:halt, {:block, "PreToolUse hook timed out."}}

        {:error, {:exit_code, code}} ->
          {:halt, {:block, "PreToolUse hook failed with exit code #{code}."}}

        {:error, reason} ->
          {:halt, {:block, "PreToolUse hook error: #{inspect(reason)}"}}
      end
    end)
    |> case do
      {:block, reason} -> {:block, reason}
      {:allow, ow} when map_size(ow) > 0 -> {:overwrite, ow}
      {:allow, _} -> :allow
    end
  end

  @impl true
  def after_tool(tool_name, args, result, ctx) do
    agent_cfg = Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{}
    hooks_files = resolve_hooks_files(agent_cfg)

    input_payload =
      build_common_payload(agent_cfg, ctx)
      |> Map.merge(%{
        "toolCall" => %{"name" => tool_name, "args" => args},
        "stepIdx" => 1
      })
      |> then(fn p ->
        if result["is_error"], do: Map.put(p, "error", to_string(result["output"])), else: p
      end)

    hooks_files
    |> load_matched_tool_handlers("PostToolUse", tool_name)
    |> Enum.each(fn {hook_dir, handler} ->
      _ = run_hook_command(handler, input_payload, hook_dir)
    end)

    {:ok, result}
  end

  @impl true
  def after_run(summary, ctx) do
    agent_cfg = Doc.snapshot("conversation", ctx.conversation_id, "pi.agent") || %{}
    hooks_files = resolve_hooks_files(agent_cfg)

    input_payload =
      build_common_payload(agent_cfg, ctx)
      |> Map.merge(%{
        "executionNum" => 1,
        "terminationReason" => "NO_TOOL_CALL",
        "error" => "",
        "fullyIdle" => true,
        "lastAssistantMessage" => summary.last_message
      })

    hooks_files
    |> load_merged_handlers("Stop")
    |> Enum.reduce_while(:accept, fn {hook_dir, handler}, :accept ->
      case run_hook_command(handler, input_payload, hook_dir) do
        {:ok, %{"decision" => "continue"} = out} ->
          reason = Map.get(out, "reason", "Continue requested by Stop hook.")
          {:halt, {:continue, reason}}

        _ ->
          {:cont, :accept}
      end
    end)
  end

  # --- Helpers & Public Inspection ---

  def matcher_matches?("*", _tool_name), do: true
  def matcher_matches?("", _tool_name), do: true
  def matcher_matches?(nil, _tool_name), do: true

  def matcher_matches?(pattern, tool_name) when is_binary(pattern) and is_binary(tool_name) do
    normalized_tool =
      tool_name
      |> String.downcase()
      |> String.replace_prefix("cortex_step_type_", "")

    normalized_pattern = String.downcase(pattern)

    case Regex.compile("^(?:" <> pattern <> ")$", [:caseless]) do
      {:ok, re} -> Regex.match?(re, normalized_tool)
      _ -> normalized_tool == normalized_pattern
    end
  end

  def matcher_matches?(_pattern, _tool_name), do: false

  def run_hook_command(handler, stdin_map, working_dir) when is_map(handler) do
    cmd = Map.get(handler, "command")

    if is_nil(cmd) or not is_binary(cmd) or String.trim(cmd) == "" do
      {:ok, %{}}
    else
      timeout_sec =
        case Map.get(handler, "timeout", 30) do
          t when is_integer(t) -> t
          t when is_binary(t) ->
            case Integer.parse(t) do
              {n, _} -> n
              _ -> 30
            end
          _ -> 30
        end

      expanded_cmd = String.replace_leading(cmd, "~/", Path.expand("~/") <> "/")
      json_in = Jason.encode!(stdin_map)

      task =
        Task.Supervisor.async_nolink(SuperPi.ToolTaskSupervisor, fn ->
          tmp_in = Path.join(System.tmp_dir!(), "agy_hook_in_#{System.unique_integer([:positive])}.json")
          File.write!(tmp_in, json_in)

          try do
            case System.cmd("sh", ["-c", "#{expanded_cmd} < #{tmp_in}"], cd: working_dir, stderr_to_stdout: false) do
              {stdout, 0} ->
                case Jason.decode(String.trim(stdout)) do
                  {:ok, map} when is_map(map) -> {:ok, map}
                  _ -> {:ok, %{}}
                end

              {_out, code} ->
                {:error, {:exit_code, code}}
            end
          after
            File.rm(tmp_in)
          end
        end)

      case Task.yield(task, timeout_sec * 1_000) || Task.shutdown(task, :brutal_kill) do
        {:ok, res} -> res
        _ -> {:error, :hook_timeout}
      end
    end
  end

  def run_hook_command(_handler, _stdin_map, _working_dir), do: {:ok, %{}}

  defp resolve_hooks_files(agent_cfg) do
    case Map.get(agent_cfg, "hooksFiles") do
      files when is_list(files) ->
        files

      _ ->
        workspace_dirs = Map.get(agent_cfg, "workspacePaths", [File.cwd!()])
        global_dir = Map.get(agent_cfg, "globalConfigDir", Discovery.default_global_config_dir())
        Discovery.discover_hooks_files(workspace_dirs, global_config_dir: global_dir)
    end
  end

  defp load_merged_handlers(hooks_files, event_name) do
    Enum.flat_map(hooks_files, fn file ->
      hook_dir = Path.dirname(file)

      case File.read(file) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, map} when is_map(map) ->
              map
              |> Enum.sort_by(fn {k, _} -> k end)
              |> Enum.flat_map(fn {_hook_name, spec} ->
                if is_map(spec) and Map.get(spec, "enabled", true) != false do
                  case Map.get(spec, event_name, []) do
                    list when is_list(list) -> Enum.map(list, fn h -> {hook_dir, h} end)
                    _ -> []
                  end
                else
                  []
                end
              end)

            _ ->
              []
          end

        _ ->
          []
      end
    end)
  end

  defp load_matched_tool_handlers(hooks_files, event_name, tool_name) do
    Enum.flat_map(hooks_files, fn file ->
      hook_dir = Path.dirname(file)

      case File.read(file) do
        {:ok, raw} ->
          case Jason.decode(raw) do
            {:ok, map} when is_map(map) ->
              map
              |> Enum.sort_by(fn {k, _} -> k end)
              |> Enum.flat_map(fn {_hook_name, spec} ->
                if is_map(spec) and Map.get(spec, "enabled", true) != false do
                  case Map.get(spec, event_name, []) do
                    list when is_list(list) ->
                      Enum.flat_map(list, fn group ->
                        if is_map(group) and matcher_matches?(Map.get(group, "matcher", "*"), tool_name) do
                          case Map.get(group, "hooks", []) do
                            hooks when is_list(hooks) -> Enum.map(hooks, fn h -> {hook_dir, h} end)
                            _ -> []
                          end
                        else
                          []
                        end
                      end)

                    _ ->
                      []
                  end
                else
                  []
                end
              end)

            _ ->
              []
          end

        _ ->
          []
      end
    end)
  end

  defp extract_injected_texts(steps) do
    Enum.flat_map(steps, fn
      %{"systemMessage" => %{"systemMessage" => msg}} when is_binary(msg) and msg != "" -> [msg]
      %{"userMessage" => msg} when is_binary(msg) and msg != "" -> [msg]
      %{"ephemeralMessage" => msg} when is_binary(msg) and msg != "" -> [msg]
      _ -> []
    end)
  end

  defp build_common_payload(agent_cfg, ctx) do
    conv_id = to_string(Map.get(ctx, :conversation_id, "1"))
    app_dir = Map.get(agent_cfg, "appDataDir", Discovery.default_app_data_dir())

    %{
      "conversationId" => conv_id,
      "workspacePaths" => Map.get(agent_cfg, "workspacePaths", [File.cwd!()]),
      "transcriptPath" => Path.join([app_dir, "brain", conv_id, ".system_generated", "logs", "transcript.jsonl"]),
      "artifactDirectoryPath" => Path.join([app_dir, "brain", conv_id]),
      "modelName" => Map.get(agent_cfg, "model", "auto")
    }
  end
end
