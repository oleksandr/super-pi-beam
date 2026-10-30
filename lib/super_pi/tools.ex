defmodule SuperPi.Tools do
  @moduledoc """
  Built-in 3-Channel Tool Suite, 5 `ToolExposure` Modes, and Deferred `tool_search` Registry (`Step 8`).

  ## 3-Channel Tool Results (`Decision 06`)
  Every tool execution returns a normalized map with:
  - `"output"` — Concise string sent to the LLM context (`pi.message` role `tool`).
  - `"structured_output"` — Typed JSON map for programmatic consumers and Codemode scripts.
  - `"details"` — Rich metadata (`diff`, `line_count`, `spilled_path`, `duration_ms`) for UI inspectors.
  - `"control"` (optional) — Control directives (`%{"add_tools" => [...]}`, `%{"handoff" => ...}`, `%{"terminate" => true}`).

  ## 5 `ToolExposure` Modes
  - `:direct` — Exposed in the active LLM tool declarations and callable from Codemode.
  - `:model_only` — Exposed in the LLM tool declarations only (e.g., `tool_search`).
  - `:codemode` — Callable inside Codemode scripts only; omitted from top-level LLM declarations to save tokens.
  - `:deferred` — Omitted from initial LLM declarations; discovered and activated dynamically via `tool_search`.
  - `:hidden` — Internal/disabled tool.
  """

  alias SuperPi.Env.Workspace

  @catalog_ets :super_pi_tool_catalog

  @type exposure :: :direct | :model_only | :codemode | :deferred | :hidden

  @effects ~w(read fs_write exec net_read net_write state_write)

  # Effects of the built-in tools and of aliases that a model may call.
  @builtin_effects %{
    "read" => ["read"],
    "read_file" => ["read"],
    "grep" => ["read"],
    "search_files" => ["read"],
    "find" => ["read"],
    "find_files" => ["read"],
    "ls" => ["read"],
    "list_dir" => ["read"],
    "list_directory" => ["read"],
    "tool_search" => ["read"],
    "artifact_put" => ["state_write"],
    "artifact_get" => ["read"],
    "artifact_list" => ["read"],
    "write" => ["fs_write"],
    "write_file" => ["fs_write"],
    "edit" => ["fs_write"],
    "edit_file" => ["fs_write"],
    "bash" => ["exec"],
    "sh" => ["exec"],
    "terminal" => ["exec"],
    "run_command" => ["exec"],
    "exec" => ["exec"]
  }

  @doc "The effect vocabulary: `read`, `fs_write`, `exec`, `net_read`, `net_write`, `state_write`."
  @spec effect_vocabulary() :: [String.t()]
  def effect_vocabulary, do: @effects

  @doc """
  Effects of a tool: what a call changes or reaches.

  | Effect | Meaning |
  |---|---|
  | `read` | Reads the workspace or answers from existing state. Changes nothing. |
  | `fs_write` | Writes workspace files. |
  | `exec` | Runs a command. |
  | `net_read` | Reads from the network (a GET). |
  | `net_write` | Sends data out or changes a remote system. |
  | `state_write` | Changes Super-Pi state (artifacts, todos, memory, schedules), not the workspace. |

  A tool states its effects in an `"effects"` list on its spec. The lookup order is: the spec in
  `agent_cfg["tools"]` (plugin tools live there), the catalog, then the table for built-in tools.
  `nil` means the tool is unknown, which every policy treats as the most dangerous kind.
  """
  @spec effects(String.t(), map() | nil) :: [String.t()] | nil
  def effects(tool_name, agent_cfg \\ nil) when is_binary(tool_name) do
    from_cfg =
      with %{} <- agent_cfg,
           [_ | _] = tools <- Map.get(agent_cfg, "tools"),
           %{} = spec <- Enum.find(tools, &(is_map(&1) and &1["name"] == tool_name)) do
        valid_effects(spec["effects"])
      else
        _ -> nil
      end

    from_cfg || from_catalog(tool_name) || Map.get(@builtin_effects, tool_name)
  end

  defp from_catalog(tool_name) do
    ensure_catalog_ets!()

    case :ets.lookup(@catalog_ets, tool_name) do
      [{_, spec}] -> valid_effects(spec["effects"])
      _ -> nil
    end
  end

  defp valid_effects([_ | _] = list), do: if(Enum.all?(list, &(&1 in @effects)), do: list)
  defp valid_effects(_), do: nil

  def ensure_catalog_ets! do
    case :ets.whereis(@catalog_ets) do
      :undefined ->
        heir = Process.whereis(SuperPi.Durable.DeferredFlusher)

        opts = [
          :named_table,
          :public,
          :set,
          read_concurrency: true
        ]

        opts = if heir, do: [{:heir, heir, :catalog} | opts], else: opts

        try do
          tid = :ets.new(@catalog_ets, opts)
          seed_builtin_tools!()

          if heir && heir != self() do
            try do
              :ets.give_away(tid, heir, :catalog)
            rescue
              _ -> :ok
            end
          end

          tid
        rescue
          ArgumentError ->
            :ets.whereis(@catalog_ets)
        end

      tid ->
        tid
    end
  end

  @doc """
  Registers a tool specification in the ETS catalog with one of the 5 `ToolExposure` modes.
  """
  def register_tool!(%{"name" => name} = spec, exposure \\ :direct)
      when is_binary(name) and exposure in [:direct, :model_only, :codemode, :deferred, :hidden] do
    ensure_catalog_ets!()
    entry = tool_entry(spec, exposure)
    :ets.insert(@catalog_ets, {name, entry})
    entry
  end

  @doc "The catalog form of a tool spec: one `\"parameters\"` key for the schema, whatever the source called it."
  def tool_entry(%{"name" => name} = spec, exposure) do
    spec
    |> Map.drop(["input_schema", "inputSchema"])
    |> Map.put("parameters", SuperPi.AI.ToolSchemas.parameters(spec, name))
    |> Map.put("exposure", Atom.to_string(exposure))
  end

  @doc """
  Returns all tools that should be declared in the initial LLM request (`:direct` and `:model_only`).
  """
  def active_llm_tools do
    ensure_catalog_ets!()

    :ets.tab2list(@catalog_ets)
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(&1["exposure"] in ["direct", "model_only"]))
    |> Enum.sort_by(& &1["name"])
  end

  @doc """
  Searches `:deferred` (and `:direct`) tools by keyword query (`tool_search`) and returns matching
  tool schemas along with a `control: %{"add_tools" => matches}` directive that activates them
  in `pi.agent` (`Decision 06`).
  """
  def tool_search(query, max_results \\ 10)

  def tool_search(query, _max_results) when not is_binary(query) do
    error_result("tool_search", "Query must be a string")
  end

  def tool_search(query, max_results) when is_binary(query) do
    ensure_catalog_ets!()
    q_down = String.downcase(String.trim(query))

    if q_down == "" do
      %{
        "output" => "No search query provided.",
        "structured_output" => %{"matches" => [], "count" => 0},
        "details" => %{"query" => query, "activated_names" => []},
        "control" => %{"add_tools" => []}
      }
    else
      matches =
        :ets.tab2list(@catalog_ets)
        |> Enum.map(&elem(&1, 1))
        |> Enum.filter(fn tool ->
          tool["exposure"] in ["deferred", "direct"] and
            (String.contains?(String.downcase(tool["name"]), q_down) or
               String.contains?(String.downcase(Map.get(tool, "description", "")), q_down))
        end)
        |> Enum.sort_by(& &1["name"])
        |> Enum.take(max_results)

      names = Enum.map(matches, & &1["name"])

      %{
        "output" => "Activated #{length(matches)} matching tools: #{Enum.join(names, ", ")}",
        "structured_output" => %{"matches" => matches, "count" => length(matches)},
        "details" => %{"query" => query, "activated_names" => names},
        "control" => %{"add_tools" => matches}
      }
    end
  end

  @doc """
  Executes one of the 7 built-in tools (`read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`) or `tool_search`.
  Supports common tool name aliases and argument variations with defensive parameter extraction.
  """
  def execute(tool_name, args, ctx \\ %{})

  def execute(tool_name, args, _ctx) when not is_binary(tool_name) or not is_map(args) do
    error_result(
      to_string(tool_name),
      "Invalid tool execution arguments: tool_name must be a string and args must be a map"
    )
  end

  def execute(tool_name, args, ctx) when is_binary(tool_name) and is_map(args) do
    ensure_catalog_ets!()

    if String.starts_with?(tool_name, "mcp__") do
      with {:ok, ws} <- Workspace.resolve(ctx || %{}),
           true <- :net in ws.capabilities do
        SuperPi.MCP.Manager.call_tool(tool_name, args, conversation_scope(ctx))
      else
        false ->
          error_result(
            tool_name,
            "#{tool_name} needs network access, which this workspace does not allow"
          )

        {:error, message} ->
          error_result(tool_name, message)
      end
    else
      # The workspace (`SuperPi.Env.Workspace`) decides where file and command tools act, and
      # which tools exist at all. A tool is never run against another place than the one configured.
      case Workspace.resolve(ctx || %{}) do
        {:ok, ws} ->
          if Workspace.supports?(ws, tool_name, agent_cfg(ctx)) do
            try do
              ws |> then(&run(tool_name, args, &1, ctx || %{})) |> add_notice(ws)
            catch
              {:workspace_error, message} -> error_result(tool_name, message)
            end
          else
            error_result(tool_name, "#{tool_name} is not available in a #{ws.kind} workspace")
          end

        {:error, message} ->
          error_result(tool_name, message)
      end
    end
  end

  defp conversation_scope(%{conversation_id: id}) when not is_nil(id), do: id
  defp conversation_scope(_ctx), do: :global

  defp agent_cfg(%{conversation_id: id}) when not is_nil(id),
    do: SuperPi.Durable.Doc.snapshot("conversation", id, "pi.agent")

  defp agent_cfg(_ctx), do: nil

  defp add_notice(%{"output" => out} = result, %{notice: notice})
       when is_binary(notice) and is_binary(out) do
    Map.put(result, "output", notice <> "\n" <> out)
  end

  defp add_notice(result, _ws), do: result

  defp default_dir(%{root: root}) when is_binary(root), do: root
  defp default_dir(_ws), do: File.cwd!()

  # A directory argument. In a confined workspace it must lie inside the root.
  defp ws_dir(%{confined?: true} = ws, value), do: Workspace.contain!(ws, value || ".")
  defp ws_dir(ws, value), do: value || default_dir(ws)

  defp ws_path(%{confined?: true} = ws, path, args),
    do: Workspace.contain!(ws, path, fetch_arg(args, [:cd, "cd", :dir, "dir", :cwd, "cwd"]))

  defp ws_path(_ws, path, args), do: resolve_path(path, args)

  defp run(tool_name, args, ws, ctx) do
    env = ws.env

    case tool_name do
      name when name in ["read", "read_file"] ->
        case fetch_arg(args, [:path, "path", :file_path, "file_path"]) do
          nil ->
            error_result(name, "Missing required argument 'path'")

          path when not is_binary(path) ->
            error_result(name, "Argument 'path' must be a string")

          path ->
            path = ws_path(ws, path, args)
            offset = fetch_arg(args, [:offset, "offset", :start_line, "start_line"], 1)
            limit = fetch_arg(args, [:limit, "limit", :end_line, "end_line"])

            # An ACP client may serve the read, to give the unsaved editor buffer (`Env.ClientFS`).
            read =
              case SuperPi.Env.ClientFS.maybe_read(ctx, ws, path, line: offset, limit: limit) do
                {:ok, content} -> {:ok, content}
                {:error, reason} -> {:error, reason}
                :skip -> env.read_file(path, offset: offset, limit: limit)
              end

            case read do
              {:ok, content} ->
                line_count = length(String.split(content, "\n"))

                %{
                  "output" => content,
                  "structured_output" => %{"path" => path, "lines" => line_count},
                  "details" => %{"path" => path, "line_count" => line_count}
                }

              {:error, reason} ->
                error_result(name, reason)
            end
        end

      name when name in ["write", "write_file"] ->
        path = fetch_arg(args, [:path, "path", :file_path, "file_path"])
        content = fetch_arg(args, [:content, "content", :contents, "contents"])

        cond do
          is_nil(path) ->
            error_result(name, "Missing required argument 'path'")

          is_nil(content) ->
            error_result(name, "Missing required argument 'content'")

          true ->
            resolved_path = ws_path(ws, path, args)

            case env.write_file(resolved_path, content) do
              :ok ->
                bytes = byte_size(content)

                %{
                  "output" => "Wrote #{bytes} bytes to #{path}",
                  "structured_output" => %{"path" => path, "bytes" => bytes},
                  "details" => %{"path" => path, "bytes_written" => bytes}
                }

              {:error, reason} ->
                error_result(name, reason)
            end
        end

      name when name in ["edit", "edit_file"] ->
        path = fetch_arg(args, [:path, "path", :file_path, "file_path"])

        old_text =
          fetch_arg(args, [
            :old_text,
            "old_text",
            :oldText,
            "oldText",
            :old_string,
            "old_string",
            :target,
            "target"
          ])

        new_text =
          fetch_arg(args, [
            :new_text,
            "new_text",
            :newText,
            "newText",
            :new_string,
            "new_string",
            :replacement,
            "replacement"
          ])

        cond do
          is_nil(path) ->
            error_result(name, "Missing required argument 'path'")

          is_nil(old_text) ->
            error_result(name, "Missing required argument 'old_text'")

          is_nil(new_text) ->
            error_result(name, "Missing required argument 'new_text'")

          true ->
            resolved_path = ws_path(ws, path, args)

            case env.edit_file(resolved_path, old_text, new_text) do
              {:ok, %{replacements: count}} ->
                %{
                  "output" => "Replaced #{count} occurrence(s) in #{path}",
                  "structured_output" => %{"path" => path, "replacements" => count},
                  "details" => %{"path" => path, "replacements" => count}
                }

              {:error, reason} ->
                error_result(name, reason)
            end
        end

      name when name in ["bash", "sh", "terminal", "run_command", "exec"] ->
        command = fetch_arg(args, [:command, "command", :cmd, "cmd", :script, "script"])
        cd = ws_dir(ws, fetch_arg(args, [:cd, "cd", :dir, "dir", :cwd, "cwd"]))

        case command do
          nil ->
            error_result(name, "Missing required argument 'command'")

          cmd ->
            case env.exec_command("sh", ["-c", cmd], cd: cd) do
              {:ok, %{exit_code: code, output: out, spilled_path: spilled}} ->
                %{
                  "is_error" => code != 0,
                  "output" => out,
                  "structured_output" => %{"exit_code" => code, "spilled_path" => spilled},
                  "details" => %{"exit_code" => code, "spilled_path" => spilled, "command" => cmd}
                }

              {:error, reason} ->
                error_result(name, reason)
            end
        end

      name when name in ["grep", "search_files"] ->
        root = ws_dir(ws, fetch_arg(args, [:path, "path", :dir, "dir"]))
        pattern = fetch_arg(args, [:pattern, "pattern", :query, "query"])

        case pattern do
          nil ->
            error_result(name, "Missing required argument 'pattern'")

          pat ->
            case env.scan_lines(root, pat) do
              {:ok, matches} ->
                formatted =
                  matches
                  |> Enum.map(fn m -> "#{m.path}:#{m.line}:#{m.text}" end)
                  |> Enum.join("\n")

                %{
                  "output" => formatted,
                  "structured_output" => %{"matches" => matches, "count" => length(matches)},
                  "details" => %{"match_count" => length(matches)}
                }

              {:error, reason} ->
                error_result(name, reason)
            end
        end

      name when name in ["find", "find_files"] ->
        root = ws_dir(ws, fetch_arg(args, [:path, "path", :dir, "dir"]))
        pattern = fetch_arg(args, [:pattern, "pattern", :glob, "glob"])

        case env.list_files(root) do
          {:ok, files} ->
            filtered = filter_files_by_pattern(files, pattern)

            %{
              "output" => Enum.join(filtered, "\n"),
              "structured_output" => %{"files" => filtered, "count" => length(filtered)},
              "details" => %{"file_count" => length(filtered)}
            }

          {:error, reason} ->
            error_result(name, reason)
        end

      name when name in ["ls", "list_dir", "list_directory"] ->
        dir = ws_dir(ws, fetch_arg(args, [:path, "path", :dir, "dir"]))

        case File.ls(Path.expand(dir)) do
          {:ok, entries} ->
            sorted = Enum.sort(entries)

            %{
              "output" => Enum.join(sorted, "\n"),
              "structured_output" => %{"entries" => sorted},
              "details" => %{"count" => length(sorted)}
            }

          {:error, reason} ->
            error_result(name, reason)
        end

      "tool_search" ->
        query = fetch_arg(args, [:query, "query"], "")
        tool_search(query)

      "artifact_" <> _ ->
        SuperPi.Artifacts.Tools.run(tool_name, args, ws, ctx)

      other ->
        error_result(other, :unknown_tool)
    end
  end

  defp resolve_path(path, args) when is_binary(path) do
    case fetch_arg(args, [:cd, "cd", :dir, "dir", :cwd, "cwd"]) do
      cd when is_binary(cd) and cd != "" ->
        if Path.type(path) == :relative do
          Path.expand(path, cd)
        else
          path
        end

      _ ->
        path
    end
  end

  defp resolve_path(path, _args), do: path

  defp filter_files_by_pattern(files, nil), do: files
  defp filter_files_by_pattern(files, ""), do: files

  defp filter_files_by_pattern(files, pattern) when is_binary(pattern) do
    tokens =
      Regex.scan(~r/(\*\*|\*|\?|[^\*\?]+)/, pattern)
      |> Enum.map(fn [_, t] ->
        case t do
          "**" -> ".*"
          "*" -> "[^/]*"
          "?" -> "[^/]"
          other -> Regex.escape(other)
        end
      end)
      |> Enum.join()

    case Regex.compile("(?:^|/)" <> tokens <> "$") do
      {:ok, regex} ->
        Enum.filter(files, fn file ->
          Regex.match?(regex, file) or Regex.match?(regex, Path.basename(file))
        end)

      _ ->
        files
    end
  end

  defp filter_files_by_pattern(files, _pattern), do: files

  defp fetch_arg(args, keys, default \\ nil) when is_map(args) and is_list(keys) do
    Enum.find_value(keys, default, fn k ->
      Map.get(args, k) || Map.get(args, to_string(k))
    end)
  end

  @doc """
  Builds the error result for a tool that is registered but has no implementation.

  A tool that cannot do its job must report an error. It must never report success.
  """
  @spec not_implemented_result(String.t()) :: map()
  def not_implemented_result(tool) do
    %{
      "is_error" => true,
      "output" => "Tool #{tool} is not implemented",
      "structured_output" => %{"status" => "not_implemented", "error" => "not_implemented"},
      "details" => %{"error" => "not_implemented"}
    }
  end

  defp error_result(tool, reason) do
    %{
      "is_error" => true,
      "output" => "Tool #{tool} failed: #{inspect(reason)}",
      "structured_output" => %{"error" => inspect(reason)},
      "details" => %{"error" => inspect(reason)}
    }
  end

  defp seed_builtin_tools! do
    builtins = [
      {%{
         "name" => "read",
         "description" => "Read file contents with optional line offset and limit"
       }, :direct},
      {%{"name" => "write", "description" => "Write full contents to a file under FileLock"},
       :direct},
      {%{"name" => "edit", "description" => "Replace exact text in a file under FileLock"},
       :direct},
      {%{
         "name" => "bash",
         "description" => "Execute shell command safely with 4 MiB spill protection"
       }, :direct},
      {%{"name" => "grep", "description" => "Search files by regex pattern"}, :direct},
      {%{"name" => "find", "description" => "List non-ignored files in a directory tree"},
       :direct},
      {%{"name" => "ls", "description" => "List immediate directory entries"}, :direct},
      {%{
         "name" => "tool_search",
         "description" => "Search and activate deferred tools by keyword"
       }, :model_only}
    ]

    Enum.each(builtins, fn {spec, exp} ->
      :ets.insert(@catalog_ets, {spec["name"], Map.put(spec, "exposure", Atom.to_string(exp))})
    end)
  end
end
