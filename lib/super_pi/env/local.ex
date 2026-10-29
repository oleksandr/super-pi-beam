defmodule SuperPi.Env.Local do
  @moduledoc """
  Local host execution environment implementing `SuperPi.Env.Behaviour` (`REQ-SAFE-01`..`REQ-SAFE-04`).

  Combines:
  - `SuperPi.Env.FileLock` per `{env_id, canonical_path}` for atomic, serialized `write_file` and `edit_file`
  - `SuperPi.Env.SandboxRunner` (`Task.Supervisor.async_nolink` + `:max_heap_size` + `Exile` spill files)
  - Gitignore-aware fast directory walk and regex line scanner (`list_files/2` and `scan_lines/3`)
  """

  @behaviour SuperPi.Env.Behaviour

  alias SuperPi.Env.{FileLock, SandboxRunner}

  @default_env_id "local"

  @impl true
  def id, do: @default_env_id

  @impl true
  def read_file(path, opts \\ []) when is_binary(path) do
    SandboxRunner.run_isolated(fn ->
      case File.read(Path.expand(path)) do
        {:ok, content} ->
          offset = Keyword.get(opts, :offset, 1)
          limit = Keyword.get(opts, :limit)
          safe_content = ensure_valid_utf8(content)
          {:ok, slice_lines(safe_content, offset, limit)}

        {:error, reason} ->
          {:error, reason}
      end
    end)
    |> unwrap_sandbox()
  end

  @impl true
  def write_file(path, content, opts \\ []) when is_binary(path) and is_binary(content) do
    env_id = Keyword.get(opts, :env_id, @default_env_id)
    expanded = Path.expand(path)

    FileLock.with_lock(env_id, expanded, fn ->
      atomic_write(expanded, content)
    end)
  end

  @impl true
  def edit_file(path, old_text, new_text, opts \\ [])

  def edit_file(_path, "", _new_text, _opts) do
    {:error, :empty_old_text}
  end

  def edit_file(path, old_text, new_text, opts)
      when is_binary(path) and is_binary(old_text) and is_binary(new_text) do
    env_id = Keyword.get(opts, :env_id, @default_env_id)
    expanded = Path.expand(path)

    FileLock.with_lock(env_id, expanded, fn ->
      case File.read(expanded) do
        {:ok, content} ->
          parts = String.split(content, old_text)
          count = length(parts) - 1

          if count == 0 do
            {:error, :target_not_found}
          else
            updated = Enum.join(parts, new_text)

            case atomic_write(expanded, updated) do
              :ok -> {:ok, %{replacements: count}}
              {:error, reason} -> {:error, reason}
            end
          end

        {:error, reason} ->
          {:error, reason}
      end
    end)
  end

  defp atomic_write(path, content) do
    dir = Path.dirname(path)
    File.mkdir_p!(dir)
    tmp = Path.join(dir, ".#{Path.basename(path)}.tmp.#{System.unique_integer([:positive])}")

    case File.write(tmp, content) do
      :ok ->
        case File.rename(tmp, path) do
          :ok ->
            :ok

          {:error, reason} ->
            File.rm(tmp)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_files(root_dir, opts \\ []) when is_binary(root_dir) do
    max_results = Keyword.get(opts, :max_results, 5_000)

    SandboxRunner.run_isolated(fn ->
      expanded_root = Path.expand(root_dir)
      ignored_names = MapSet.new([".git", "_build", "deps", "node_modules", ".elixir_ls"])
      gitignore_rules = load_gitignore_rules(expanded_root, expanded_root)

      visited_inodes =
        case File.stat(expanded_root) do
          {:ok, %{major_device: dev, inode: ino}} -> MapSet.new([{dev, ino}])
          _ -> MapSet.new()
        end

      files =
        walk_dir(expanded_root, expanded_root, ignored_names, gitignore_rules, visited_inodes, [])
        |> Enum.sort()
        |> Enum.take(max_results)

      {:ok, files}
    end)
    |> unwrap_sandbox()
  end

  @impl true
  def scan_lines(root_dir, pattern, opts \\ []) when is_binary(root_dir) and is_binary(pattern) do
    max_matches = Keyword.get(opts, :max_matches, 500)

    SandboxRunner.run_isolated(fn ->
      case Regex.compile(pattern) do
        {:ok, regex} ->
          {:ok, rel_files} = list_files(root_dir, opts)
          expanded_root = Path.expand(root_dir)

          matches =
            Enum.reduce_while(rel_files, [], fn rel_path, acc ->
              full = Path.join(expanded_root, rel_path)

              case File.read(full) do
                {:ok, bin} ->
                  if String.valid?(bin) do
                    file_matches =
                      bin
                      |> String.split("\n")
                      |> Enum.with_index(1)
                      |> Enum.reduce([], fn {line, line_no}, m_acc ->
                        if Regex.match?(regex, line) do
                          [%{path: rel_path, line: line_no, text: line} | m_acc]
                        else
                          m_acc
                        end
                      end)
                      |> Enum.reverse()

                    combined = acc ++ file_matches

                    if length(combined) >= max_matches do
                      {:halt, Enum.take(combined, max_matches)}
                    else
                      {:cont, combined}
                    end
                  else
                    {:cont, acc}
                  end

                _ ->
                  {:cont, acc}
              end
            end)

          {:ok, matches}

        {:error, reason} ->
          {:error, {:invalid_regex, reason}}
      end
    end)
    |> unwrap_sandbox()
  end

  @impl true
  def exec_command(cmd, args \\ [], opts \\ []) do
    SandboxRunner.exec_command(cmd, args, opts)
  end

  # --- Helpers ---

  defp unwrap_sandbox({:ok, {:ok, val}}), do: {:ok, val}
  defp unwrap_sandbox({:ok, :ok}), do: :ok
  defp unwrap_sandbox({:ok, {:error, err}}), do: {:error, err}
  defp unwrap_sandbox({:error, err}), do: {:error, err}

  defp ensure_valid_utf8(content) when is_binary(content) do
    if String.valid?(content) do
      content
    else
      :unicode.characters_to_binary(content, :latin1, :utf8)
    end
  end

  defp slice_lines(content, offset, nil) when offset <= 1, do: content

  defp slice_lines(content, offset, limit) do
    lines = String.split(content, "\n")
    start_idx = max(offset - 1, 0)
    sliced = Enum.drop(lines, start_idx)
    sliced = if is_integer(limit), do: Enum.take(sliced, limit), else: sliced
    Enum.join(sliced, "\n")
  end

  defp load_gitignore_rules(dir, root_dir) do
    gitignore_path = Path.join(dir, ".gitignore")
    dir_rel = if dir == root_dir, do: "", else: Path.relative_to(dir, root_dir)

    case File.read(gitignore_path) do
      {:ok, content} ->
        content
        |> String.split("\n")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> Enum.map(&parse_gitignore_line(&1, dir_rel))
        |> Enum.reject(&is_nil/1)

      _ ->
        []
    end
  end

  defp parse_gitignore_line(clean, dir_rel) do
    {negated, pat} =
      if String.starts_with?(clean, "!") do
        {true, String.slice(clean, 1..-1//1)}
      else
        {false, clean}
      end

    pat = String.trim_trailing(pat, "/")
    leading_slash = String.starts_with?(pat, "/")
    pat = String.trim_leading(pat, "/")
    has_inner_slash = String.contains?(pat, "/")
    anchored = leading_slash or has_inner_slash

    case glob_to_regex(pat, anchored) do
      {:ok, regex} -> %{negated?: negated, dir_rel: dir_rel, regex: regex}
      _ -> nil
    end
  end

  defp glob_to_regex(pat, anchored) do
    tokens =
      Regex.scan(~r/(\*\*|\*|\?|[^\*\?]+)/, pat)
      |> Enum.map(fn [_, t] ->
        case t do
          "**" -> ".*"
          "*" -> "[^/]*"
          "?" -> "[^/]"
          other -> Regex.escape(other)
        end
      end)
      |> Enum.join()

    tokens =
      tokens
      |> String.replace("/.*/", "/(?:.+/)?")
      |> String.replace("^.*/", "^(?:.+/)?")

    re_str =
      if anchored do
        "^" <> tokens <> "(?:/.*)?$"
      else
        "(?:^|/)" <> tokens <> "(?:/.*)?$"
      end

    Regex.compile(re_str)
  end

  defp walk_dir(current_dir, root_dir, ignored_names, rules, visited_inodes, acc) do
    current_rules =
      if current_dir != root_dir do
        rules ++ load_gitignore_rules(current_dir, root_dir)
      else
        rules
      end

    case File.ls(current_dir) do
      {:ok, entries} ->
        Enum.reduce(entries, acc, fn entry, inner_acc ->
          if MapSet.member?(ignored_names, entry) do
            inner_acc
          else
            full = Path.join(current_dir, entry)
            rel = Path.relative_to(full, root_dir)

            if ignored_by_gitignore?(rel, current_rules) do
              inner_acc
            else
              case File.stat(full) do
                {:ok, %{type: :directory, major_device: dev, inode: ino}} ->
                  if MapSet.member?(visited_inodes, {dev, ino}) do
                    inner_acc
                  else
                    walk_dir(
                      full,
                      root_dir,
                      ignored_names,
                      current_rules,
                      MapSet.put(visited_inodes, {dev, ino}),
                      inner_acc
                    )
                  end

                {:ok, %{type: :regular}} ->
                  [rel | inner_acc]

                _ ->
                  inner_acc
              end
            end
          end
        end)

      _ ->
        acc
    end
  end

  defp ignored_by_gitignore?(rel_path, rules) do
    Enum.reduce(rules, false, fn rule, ignored ->
      if applies_to_dir?(rule.dir_rel, rel_path) do
        target = rel_within_dir(rule.dir_rel, rel_path)

        if Regex.match?(rule.regex, target) do
          not rule.negated?
        else
          ignored
        end
      else
        ignored
      end
    end)
  end

  defp applies_to_dir?("", _rel_path), do: true

  defp applies_to_dir?(dir_rel, rel_path) do
    rel_path == dir_rel or String.starts_with?(rel_path, dir_rel <> "/")
  end

  defp rel_within_dir("", rel_path), do: rel_path
  defp rel_within_dir(dir_rel, rel_path), do: Path.relative_to(rel_path, dir_rel)
end
