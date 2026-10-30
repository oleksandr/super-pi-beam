defmodule SuperPi.Discovery do
  @moduledoc """
  Multi-Tier Customization Discovery Engine (`23 - Deprecating AGY and Unifying Workspace Plugins and CLI.md`).

  Discovers and resolves **Rules** (`AGENTS.md`, `GEMINI.md`, `.agents/rules/*.md`),
  **Skills** (`skills/<name>/SKILL.md`, `skills.json`),
  and **Hooks** (`hooks.json`) in strict precedence order:
  1. Workspace `.agents/` (or `.agent/`, `_agents/`, `_agent/`) walking up from `cwd` to the `.git` root.
  2. Declared workspace JSON manifests (`skills.json`, `plugins.json` with `entries`, `inherits`, `include_only`, `exclude`).
  3. Global configuration (`~/.gemini/config/` or `~/.super-pi/config/`).
  4. Built-in application skills (`~/.gemini/antigravity-cli/builtin/skills/` or `priv/skills/`).
  5. Global declared JSON manifests (`skills.json`).
  """

  @dot_dirs [".agents", ".agent", "_agents", "_agent"]

  def default_global_config_dir do
    Path.expand("~/.gemini/config")
  end

  def default_app_data_dir do
    Path.expand("~/.gemini/antigravity-cli")
  end

  @doc """
  Walks up from `start_dir` to the repository root (directory containing `.git`).
  If no `.git` boundary exists in any parent, returns `[start_dir]`.
  Returns all ancestor directories from highest priority (`start_dir`) to lowest (`repo_root`).
  """
  def ancestor_chain(start_dir) when is_binary(start_dir) do
    expanded = Path.expand(start_dir)

    case find_git_root(expanded) do
      {:ok, git_root} ->
        do_ancestor_chain_to_root(expanded, git_root, [])

      :error ->
        [expanded]
    end
  end

  defp find_git_root(dir) do
    if File.exists?(Path.join(dir, ".git")) do
      {:ok, dir}
    else
      parent = Path.dirname(dir)

      if parent == dir do
        :error
      else
        find_git_root(parent)
      end
    end
  end

  defp do_ancestor_chain_to_root(dir, git_root, acc) do
    next_acc = acc ++ [dir]

    if dir == git_root do
      next_acc
    else
      parent = Path.dirname(dir)
      do_ancestor_chain_to_root(parent, git_root, next_acc)
    end
  end

  @doc """
  Discovers all active rule files (`GEMINI.md`, `AGENTS.md`, `.agents/rules/*.md`) for `workspace_dirs`,
  deduplicating by canonical resolved path (`File.read_link` / `Path.expand`) so a rule file is never
  injected more than once.
  """
  def discover_rule_files(workspace_dirs, opts \\ []) when is_list(workspace_dirs) do
    global_dir = Keyword.get(opts, :global_config_dir, default_global_config_dir())

    workspace_candidates =
      workspace_dirs
      |> Enum.flat_map(&ancestor_chain/1)
      |> Enum.flat_map(fn dir ->
        direct = [Path.join(dir, "AGENTS.md"), Path.join(dir, "GEMINI.md")]

        dot_rules =
          Enum.flat_map(@dot_dirs, fn dot ->
            rules_dir = Path.join([dir, dot, "rules"])
            list_markdown_files(rules_dir)
          end)

        direct ++ dot_rules
      end)

    global_candidates = [
      Path.join(global_dir, "AGENTS.md"),
      Path.join(global_dir, "GEMINI.md") | list_markdown_files(Path.join(global_dir, "rules"))
    ]

    (workspace_candidates ++ global_candidates)
    |> Enum.filter(&valid_rule_file?/1)
    |> deduplicate_by_canonical_path()
  end

  defp valid_rule_file?(path) do
    File.regular?(path) and String.ends_with?(canonical_realpath(path), [".md", ".markdown"])
  end

  @doc """
  Discovers all skills across the 5 priority tiers. Higher-priority skills override lower-priority
  skills with the same `name`.
  Returns `[%{name: String.t(), description: String.t(), path: String.t(), tier: atom()}]`.
  """
  def discover_skills(workspace_dirs, opts \\ []) when is_list(workspace_dirs) do
    global_dir = Keyword.get(opts, :global_config_dir, default_global_config_dir())
    app_data_dir = Keyword.get(opts, :app_data_dir, default_app_data_dir())
    builtin_dir = Path.join([app_data_dir, "builtin", "skills"])

    ancestors = Enum.flat_map(workspace_dirs, &ancestor_chain/1) |> Enum.uniq()
    # Tier 1: Workspace `.agents/skills`
    tier1_dirs =
      for dir <- ancestors, dot <- @dot_dirs do
        Path.join([dir, dot, "skills"])
      end

    # Tier 2: Workspace `skills.json` manifests
    tier2_entries =
      for dir <- ancestors, dot <- @dot_dirs do
        manifest = Path.join([dir, dot, "skills.json"])
        resolve_json_manifest(manifest, dir)
      end
      |> List.flatten()

    # Tier 3: Global `~/.gemini/config/skills`
    tier3_dirs = [Path.join(global_dir, "skills")]

    # Tier 4: Built-in `~/.gemini/antigravity-cli/builtin/skills`
    tier4_dirs = [builtin_dir]

    # Tier 5: Global `~/.gemini/config/skills.json`
    tier5_entries = resolve_json_manifest(Path.join(global_dir, "skills.json"), global_dir)

    all_skill_Specs =
      scan_skill_dirs(tier1_dirs, :workspace) ++
        scan_manifest_skill_entries(tier2_entries, :workspace_manifest) ++
        scan_skill_dirs(tier3_dirs, :global) ++
        scan_skill_dirs(tier4_dirs, :builtin) ++
        scan_manifest_skill_entries(tier5_entries, :global_manifest)

    # Deduplicate by skill `name`, keeping highest priority first
    all_skill_Specs
    |> Enum.uniq_by(& &1.name)
  end

  @doc """
  Resolves a `skills.json` or `plugins.json` manifest recursively (`inherits` + `entries`),
  applying `include_only` and `exclude` regex/glob filters.
  """
  def resolve_json_manifest(manifest_path, repo_root, visited \\ MapSet.new()) do
    expanded = Path.expand(manifest_path)

    if MapSet.member?(visited, expanded) or not File.regular?(expanded) do
      []
    else
      visited = MapSet.put(visited, expanded)

      case File.read(expanded) |> elem_or_nil() |> decode_json_safe() do
        %{} = data ->
          base_dir = Path.dirname(expanded)

          manifest_repo_root =
            case find_git_root(base_dir) do
              {:ok, root} -> root
              _ -> repo_root || base_dir
            end

          raw_inherits =
            case Map.get(data, "inherits") do
              list when is_list(list) -> list
              _ -> []
            end

          inherited =
            raw_inherits
            |> Enum.flat_map(fn item ->
              {item_path, inc_only, exc} =
                cond do
                  is_binary(item) -> {item, nil, nil}
                  is_map(item) -> {Map.get(item, "path", ""), Map.get(item, "include_only"), Map.get(item, "exclude")}
                  true -> {"", nil, nil}
                end

              if is_binary(item_path) and item_path != "" do
                inc_path = resolve_custom_path(item_path, base_dir, manifest_repo_root)
                sub = resolve_json_manifest(inc_path, manifest_repo_root, visited)
                filter_manifest_items(sub, sanitize_patterns(inc_only), sanitize_patterns(exc))
              else
                []
              end
            end)

          raw_entries =
            case Map.get(data, "entries") do
              list when is_list(list) -> list
              _ -> []
            end

          own_entries =
            raw_entries
            |> Enum.flat_map(fn item ->
              {item_path, inc_only, exc} =
                cond do
                  is_binary(item) -> {item, nil, nil}
                  is_map(item) -> {Map.get(item, "path", ""), Map.get(item, "include_only"), Map.get(item, "exclude")}
                  true -> {"", nil, nil}
                end

              if is_binary(item_path) and item_path != "" do
                [
                  %{
                    path: resolve_custom_path(item_path, base_dir, manifest_repo_root),
                    include_only: sanitize_patterns(inc_only),
                    exclude: sanitize_patterns(exc)
                  }
                ]
              else
                []
              end
            end)

          inherited ++ own_entries

        _ ->
          []
      end
    end
  end

  defp sanitize_patterns(patterns) when is_list(patterns) do
    Enum.filter(patterns, &is_binary/1)
  end

  defp sanitize_patterns(pat) when is_binary(pat), do: [pat]
  defp sanitize_patterns(_), do: nil

  @doc """
  Parses YAML frontmatter (`name` and `description`) from a `SKILL.md` file.
  """
  def parse_skill_md(skill_md_path) when is_binary(skill_md_path) do
    case File.read(skill_md_path) do
      {:ok, raw_content} ->
        content = String.trim_leading(raw_content, "\uFEFF")

        case String.split(content, ~r/^---\s*$/m, parts: 3) do
          ["", yaml_block, body] ->
            dir_name = Path.basename(Path.dirname(skill_md_path))
            parsed_name = extract_top_level_yaml_field(yaml_block, "name")
            name = if is_nil(parsed_name) or parsed_name == "", do: dir_name, else: parsed_name
            desc = extract_top_level_yaml_field(yaml_block, "description") || ""
            {:ok, %{name: name, description: desc, path: Path.expand(skill_md_path), body: String.trim(body)}}

          _ ->
            {:error, :missing_frontmatter}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_top_level_yaml_field(yaml, key) do
    lines = String.split(yaml, "\n")

    case Enum.find_index(lines, &Regex.match?(~r/^#{key}:\s*/, &1)) do
      nil ->
        nil

      idx ->
        line = Enum.at(lines, idx)
        after_colon = line |> String.split(":", parts: 2) |> List.last() |> String.trim()
        clean_val = unquote_yaml_value(after_colon)

        continuation_lines =
          lines
          |> Enum.drop(idx + 1)
          |> Enum.take_while(fn l -> String.starts_with?(l, " ") or String.starts_with?(l, "\t") end)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        cond do
          clean_val in [">-", ">", "|", "|-", ""] and continuation_lines != [] ->
            Enum.join(continuation_lines, " ")

          continuation_lines != [] and clean_val != "" ->
            Enum.join([clean_val | continuation_lines], " ")

          true ->
            clean_val
        end
    end
  end

  defp unquote_yaml_value(val) do
    trimmed = String.trim(val)

    cond do
      String.starts_with?(trimmed, "\"") and String.ends_with?(trimmed, "\"") and byte_size(trimmed) >= 2 ->
        binary_part(trimmed, 1, byte_size(trimmed) - 2)

      String.starts_with?(trimmed, "'") and String.ends_with?(trimmed, "'") and byte_size(trimmed) >= 2 ->
        binary_part(trimmed, 1, byte_size(trimmed) - 2)

      true ->
        trimmed
    end
  end

  @doc """
  Discovers all `hooks.json` files across workspace `.agents/hooks.json`, active plugins, and `~/.gemini/config/hooks.json`.
  """
  def discover_hooks_files(workspace_dirs, opts \\ []) do
    global_dir = Keyword.get(opts, :global_config_dir, default_global_config_dir())
    ancestors = Enum.flat_map(workspace_dirs, &ancestor_chain/1) |> Enum.uniq()

    ws_hooks =
      for dir <- ancestors, dot <- @dot_dirs do
        Path.join([dir, dot, "hooks.json"])
      end

    global_hooks = [Path.join(global_dir, "hooks.json")]

    (ws_hooks ++ global_hooks)
    |> Enum.filter(&File.regular?/1)
    |> deduplicate_by_canonical_path()
  end

  # --- Helpers ---

  defp scan_skill_dirs(dirs, tier) do
    Enum.flat_map(dirs, fn dir ->
      scan_single_skill_dir(dir, tier, nil, nil)
    end)
  end

  defp scan_manifest_skill_entries(entries, tier) do
    Enum.flat_map(entries, fn entry ->
      scan_single_skill_dir(entry.path, tier, entry.include_only, entry.exclude)
    end)
  end

  defp scan_single_skill_dir(dir, tier, include_only, exclude) do
    case File.ls(dir) do
      {:ok, children} ->
        children
        |> Enum.sort()
        |> Enum.filter(&matches_filters?(&1, include_only, exclude))
        |> Enum.flat_map(fn child ->
          skill_md = Path.join([dir, child, "SKILL.md"])

          if File.regular?(skill_md) do
            case parse_skill_md(skill_md) do
              {:ok, parsed} -> [Map.put(parsed, :tier, tier)]
              _ -> []
            end
          else
            []
          end
        end)

      _ ->
        []
    end
  end

  defp filter_manifest_items(items, nil, nil), do: items

  defp filter_manifest_items(items, include_only, exclude) do
    Enum.map(items, fn item ->
      %{
        item
        | include_only: merge_filter_lists(item.include_only, include_only),
          exclude: merge_filter_lists(item.exclude, exclude)
      }
    end)
  end

  defp merge_filter_lists(nil, b), do: b
  defp merge_filter_lists(a, nil), do: a
  defp merge_filter_lists(a, b), do: Enum.uniq(a ++ b)

  defp matches_filters?(dir_name, include_only, exclude) do
    inc_ok? =
      case include_only do
        list when is_list(list) and list != [] ->
          Enum.any?(list, &pattern_matches?(dir_name, &1))

        _ ->
          true
      end

    exc_ok? =
      case exclude do
        list when is_list(list) and list != [] ->
          not Enum.any?(list, &pattern_matches?(dir_name, &1))

        _ ->
          true
      end

    inc_ok? and exc_ok?
  end

  defp pattern_matches?(name, pattern) when is_binary(pattern) do
    # `*` is a glob wildcard; everything else is treated as a regex. The whole
    # pattern is anchored as one group so alternation (`a|b`) stays anchored.
    source = String.replace(pattern, ~r/(?<![.\\\]\)])\*/, ".*")

    case Regex.compile("^(?:" <> source <> ")$") do
      {:ok, re} -> Regex.match?(re, name)
      _ -> name == pattern
    end
  end

  defp pattern_matches?(_name, _pattern), do: false

  defp resolve_custom_path("/" <> _ = abs, _base_dir, _repo_root), do: Path.expand(abs)
  defp resolve_custom_path("~/" <> _ = home, _base_dir, _repo_root), do: Path.expand(home)

  defp resolve_custom_path(rel, base_dir, repo_root) do
    candidate = Path.expand(rel, base_dir)
    if File.exists?(candidate), do: candidate, else: Path.expand(rel, repo_root)
  end

  defp list_markdown_files(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.sort()
        |> Enum.map(&Path.join(dir, &1))

      _ ->
        []
    end
  end

  defp deduplicate_by_canonical_path(paths) do
    paths
    |> Enum.reduce({[], MapSet.new()}, fn p, {acc, seen} ->
      canon = canonical_realpath(p)

      if MapSet.member?(seen, canon) do
        {acc, seen}
      else
        {acc ++ [canon], MapSet.put(seen, canon)}
      end
    end)
    |> elem(0)
  end

  defp canonical_realpath(path), do: real_path(Path.expand(path), 0)

  # Resolves every symlink component (directories and chained file links).
  defp real_path(path, depth) when depth > 40, do: path

  defp real_path(path, depth) do
    parts = Path.split(path)

    Enum.reduce(parts, "", fn
      "/", _acc ->
        "/"

      part, acc ->
        candidate = Path.join(acc, part)

        case File.read_link(candidate) do
          {:ok, target} -> real_path(Path.expand(target, acc), depth + 1)
          _ -> candidate
        end
    end)
  end

  defp elem_or_nil({:ok, v}), do: v
  defp elem_or_nil(_), do: nil

  defp decode_json_safe(nil), do: nil

  defp decode_json_safe(bin) do
    case Jason.decode(bin) do
      {:ok, val} -> val
      _ -> nil
    end
  end
end
