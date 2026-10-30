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

  alias SuperPi.Env.Local

  @catalog_ets :super_pi_tool_catalog

  @type exposure :: :direct | :model_only | :codemode | :deferred | :hidden

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
    entry = Map.put(spec, "exposure", Atom.to_string(exposure))
    :ets.insert(@catalog_ets, {name, entry})
    entry
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
    error_result(to_string(tool_name), "Invalid tool execution arguments: tool_name must be a string and args must be a map")
  end

  def execute(tool_name, args, _ctx) when is_binary(tool_name) and is_map(args) do
    ensure_catalog_ets!()

    case tool_name do
      "mcp__" <> _ ->
        SuperPi.MCP.Manager.call_tool(tool_name, args)

      name when name in ["read", "read_file"] ->
        case fetch_arg(args, [:path, "path", :file_path, "file_path"]) do
          nil ->
            error_result(name, "Missing required argument 'path'")

          path when not is_binary(path) ->
            error_result(name, "Argument 'path' must be a string")

          path ->
            path = resolve_path(path, args)
            offset = fetch_arg(args, [:offset, "offset", :start_line, "start_line"], 1)
            limit = fetch_arg(args, [:limit, "limit", :end_line, "end_line"])

            case Local.read_file(path, offset: offset, limit: limit) do
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
            resolved_path = resolve_path(path, args)

            case Local.write_file(resolved_path, content) do
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
        old_text = fetch_arg(args, [:old_text, "old_text", :oldText, "oldText", :old_string, "old_string", :target, "target"])
        new_text = fetch_arg(args, [:new_text, "new_text", :newText, "newText", :new_string, "new_string", :replacement, "replacement"])

        cond do
          is_nil(path) ->
            error_result(name, "Missing required argument 'path'")

          is_nil(old_text) ->
            error_result(name, "Missing required argument 'old_text'")

          is_nil(new_text) ->
            error_result(name, "Missing required argument 'new_text'")

          true ->
            resolved_path = resolve_path(path, args)

            case Local.edit_file(resolved_path, old_text, new_text) do
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
        cd = fetch_arg(args, [:cd, "cd", :dir, "dir", :cwd, "cwd"], File.cwd!())

        case command do
          nil ->
            error_result(name, "Missing required argument 'command'")

          cmd ->
            case Local.exec_command("sh", ["-c", cmd], cd: cd) do
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
        root = fetch_arg(args, [:path, "path", :dir, "dir"], File.cwd!())
        pattern = fetch_arg(args, [:pattern, "pattern", :query, "query"])

        case pattern do
          nil ->
            error_result(name, "Missing required argument 'pattern'")

          pat ->
            case Local.scan_lines(root, pat) do
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
        root = fetch_arg(args, [:path, "path", :dir, "dir"], File.cwd!())
        pattern = fetch_arg(args, [:pattern, "pattern", :glob, "glob"])

        case Local.list_files(root) do
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
        dir = fetch_arg(args, [:path, "path", :dir, "dir"], File.cwd!())

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
      {%{"name" => "read", "description" => "Read file contents with optional line offset and limit"}, :direct},
      {%{"name" => "write", "description" => "Write full contents to a file under FileLock"}, :direct},
      {%{"name" => "edit", "description" => "Replace exact text in a file under FileLock"}, :direct},
      {%{"name" => "bash", "description" => "Execute shell command safely with 4 MiB spill protection"}, :direct},
      {%{"name" => "grep", "description" => "Search files by regex pattern"}, :direct},
      {%{"name" => "find", "description" => "List non-ignored files in a directory tree"}, :direct},
      {%{"name" => "ls", "description" => "List immediate directory entries"}, :direct},
      {%{"name" => "tool_search", "description" => "Search and activate deferred tools by keyword"}, :model_only}
    ]

    Enum.each(builtins, fn {spec, exp} ->
      :ets.insert(@catalog_ets, {spec["name"], Map.put(spec, "exposure", Atom.to_string(exp))})
    end)
  end
end
