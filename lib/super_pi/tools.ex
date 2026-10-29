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
        tid = :ets.new(@catalog_ets, [:named_table, :public, :set, read_concurrency: true])
        seed_builtin_tools!()
        tid

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
  def tool_search(query, max_results \\ 10) when is_binary(query) do
    ensure_catalog_ets!()
    q_down = String.downcase(String.trim(query))

    matches =
      :ets.tab2list(@catalog_ets)
      |> Enum.map(&elem(&1, 1))
      |> Enum.filter(fn tool ->
        tool["exposure"] in ["deferred", "direct", "codemode"] and
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

  @doc """
  Executes one of the 7 built-in tools (`read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`) or `tool_search`.
  """
  def execute(tool_name, args, _ctx \\ %{}) when is_binary(tool_name) and is_map(args) do
    ensure_catalog_ets!()

    case tool_name do
      "read" ->
        path = Map.fetch!(args, "path")
        offset = Map.get(args, "offset", 1)
        limit = Map.get(args, "limit")

        case Local.read_file(path, offset: offset, limit: limit) do
          {:ok, content} ->
            line_count = length(String.split(content, "\n"))

            %{
              "output" => content,
              "structured_output" => %{"path" => path, "lines" => line_count},
              "details" => %{"path" => path, "line_count" => line_count}
            }

          {:error, reason} ->
            error_result("read", reason)
        end

      "write" ->
        path = Map.fetch!(args, "path")
        content = Map.fetch!(args, "content")

        case Local.write_file(path, content) do
          :ok ->
            bytes = byte_size(content)

            %{
              "output" => "Wrote #{bytes} bytes to #{path}",
              "structured_output" => %{"path" => path, "bytes" => bytes},
              "details" => %{"path" => path, "bytes_written" => bytes}
            }

          {:error, reason} ->
            error_result("write", reason)
        end

      "edit" ->
        path = Map.fetch!(args, "path")
        old_text = Map.fetch!(args, "old_text")
        new_text = Map.fetch!(args, "new_text")

        case Local.edit_file(path, old_text, new_text) do
          {:ok, %{replacements: count}} ->
            %{
              "output" => "Replaced #{count} occurrence(s) in #{path}",
              "structured_output" => %{"path" => path, "replacements" => count},
              "details" => %{"path" => path, "replacements" => count}
            }

          {:error, reason} ->
            error_result("edit", reason)
        end

      "bash" ->
        command = Map.fetch!(args, "command")
        cd = Map.get(args, "cd", File.cwd!())

        case Local.exec_command("sh", ["-c", command], cd: cd) do
          {:ok, %{exit_code: code, output: out, spilled_path: spilled}} ->
            %{
              "is_error" => code != 0,
              "output" => out,
              "structured_output" => %{"exit_code" => code, "spilled_path" => spilled},
              "details" => %{"exit_code" => code, "spilled_path" => spilled, "command" => command}
            }

          {:error, reason} ->
            error_result("bash", reason)
        end

      "grep" ->
        root = Map.get(args, "path", File.cwd!())
        pattern = Map.fetch!(args, "pattern")

        case Local.scan_lines(root, pattern) do
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
            error_result("grep", reason)
        end

      "find" ->
        root = Map.get(args, "path", File.cwd!())

        case Local.list_files(root) do
          {:ok, files} ->
            %{
              "output" => Enum.join(files, "\n"),
              "structured_output" => %{"files" => files, "count" => length(files)},
              "details" => %{"file_count" => length(files)}
            }

          {:error, reason} ->
            error_result("find", reason)
        end

      "ls" ->
        dir = Map.get(args, "path", File.cwd!())

        case File.ls(Path.expand(dir)) do
          {:ok, entries} ->
            sorted = Enum.sort(entries)

            %{
              "output" => Enum.join(sorted, "\n"),
              "structured_output" => %{"entries" => sorted},
              "details" => %{"count" => length(sorted)}
            }

          {:error, reason} ->
            error_result("ls", reason)
        end

      "tool_search" ->
        query = Map.get(args, "query", "")
        tool_search(query)

      other ->
        error_result(other, :unknown_tool)
    end
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
