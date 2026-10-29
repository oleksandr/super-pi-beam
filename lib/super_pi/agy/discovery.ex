defmodule SuperPi.AGY.Discovery do
  @moduledoc """
  5-Tier Antigravity Customization Discovery Engine (`12 - AGY Clone Specification and Gap Analysis.md`).

  Discovers and resolves **Rules** (`GEMINI.md`, `AGENTS.md`, `.agents/rules/*.md`),
  **Skills** (`skills/<name>/SKILL.md`, `skills.json`), **Plugins** (`plugins/<name>/plugin.json`, `plugins.json`),
  **Hooks** (`hooks.json`), and **MCP Configs** (`mcp_config.json`) in strict precedence order:
  1. Workspace `.agents/` (or `.agent/`, `_agents/`, `_agent/`) walking up from `cwd` to the `.git` root.
  2. Declared workspace JSON manifests (`skills.json`, `plugins.json` with `entries`, `inherits`, `include_only`, `exclude`).
  3. Global configuration (`~/.gemini/config/`).
  4. Built-in application skills (`~/.gemini/antigravity-cli/builtin/skills/`).
  5. Global declared JSON manifests (`~/.gemini/config/skills.json`, `plugins.json`).
  """

  @dot_dirs [".agents", ".agent", "_agents", "_agent"]

  def default_global_config_dir do
    Path.expand("~/.gemini/config")
  end

  def default_app_data_dir do
    Path.expand("~/.gemini/antigravity-cli")
  end

  @doc """
  Walks up from `start_dir` to the repository root (directory containing `.git` or filesystem root)
  and returns all ancestor directories from highest priority (`start_dir`) to lowest (`repo_root`).
  """
  def ancestor_chain(start_dir) when is_binary(start_dir) do
    expanded = Path.expand(start_dir)
    do_ancestor_chain(expanded, [])
  end

  defp do_ancestor_chain(dir, acc) do
    next_acc = acc ++ [dir]
    parent = Path.dirname(dir)

    if File.exists?(Path.join(dir, ".git")) or parent == dir do
      next_acc
    else
      do_ancestor_chain(parent, next_acc)
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
    |> Enum.filter(&File.regular?/1)
    |> deduplicate_by_canonical_path()
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
    repo_root = List.last(ancestors) || File.cwd!()

    # Tier 1: Workspace `.agents/skills`
    tier1_dirs =
      for dir <- ancestors, dot <- @dot_dirs do
        Path.join([dir, dot, "skills"])
      end

    # Tier 2: Workspace `skills.json` manifests
    tier2_entries =
      for dir <- ancestors, dot <- @dot_dirs do
        manifest = Path.join([dir, dot, "skills.json"])
        resolve_json_manifest(manifest, repo_root)
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

          inherited =
            data
            |> Map.get("inherits", [])
            |> Enum.flat_map(fn item ->
              inc_path = resolve_custom_path(Map.get(item, "path", ""), base_dir, repo_root)
              sub = resolve_json_manifest(inc_path, repo_root, visited)
              filter_manifest_items(sub, Map.get(item, "include_only"), Map.get(item, "exclude"))
            end)

          own_entries =
            data
            |> Map.get("entries", [])
            |> Enum.map(fn item ->
              %{
                path: resolve_custom_path(Map.get(item, "path", ""), base_dir, repo_root),
                include_only: Map.get(item, "include_only"),
                exclude: Map.get(item, "exclude")
              }
            end)

          inherited ++ own_entries

        _ ->
          []
      end
    end
  end

  @doc """
  Parses YAML frontmatter (`name` and `description`) from a `SKILL.md` file.
  """
  def parse_skill_md(skill_md_path) when is_binary(skill_md_path) do
    case File.read(skill_md_path) do
      {:ok, content} ->
        case String.split(content, ~r/^---\s*$/m, parts: 3) do
          ["", yaml_block, body] ->
            name = extract_yaml_field(yaml_block, "name") || Path.basename(Path.dirname(skill_md_path))
            desc = extract_yaml_field(yaml_block, "description") || ""
            {:ok, %{name: name, description: desc, path: Path.expand(skill_md_path), body: String.trim(body)}}

          _ ->
            {:error, :missing_frontmatter}
        end

      {:error, reason} ->
        {:error, reason}
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

  defp pattern_matches?(name, pattern) do
    case Regex.compile("^" <> pattern <> "$") do
      {:ok, re} -> Regex.match?(re, name)
      _ -> name == pattern
    end
  end

  defp resolve_custom_path("/" <> _ = abs, _base_dir, _repo_root), do: Path.expand(abs)
  defp resolve_custom_path("~/" <> _ = home, _base_dir, _repo_root), do: Path.expand(home)

  defp resolve_custom_path(rel, base_dir, repo_root) do
    candidate = Path.expand(rel, base_dir)
    if File.exists?(candidate), do: candidate, else: Path.expand(rel, repo_root)
  end

  defp extract_yaml_field(yaml, key) do
    # Handles both single-line `key: value` and multi-line `key: >-\n  line1\n  line2`
    lines = String.split(yaml, "\n")

    case Enum.find_index(lines, &String.starts_with?(String.trim_leading(&1), "#{key}:")) do
      nil ->
        nil

      idx ->
        line = Enum.at(lines, idx)
        after_colon = line |> String.split(":", parts: 2) |> List.last() |> String.trim()

        if after_colon in [">-", ">", "|", "|-", ""] do
          lines
          |> Enum.drop(idx + 1)
          |> Enum.take_while(fn l -> String.starts_with?(l, " ") or String.trim(l) == "" end)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.join(" ")
        else
          String.trim(after_colon, "\"")
        end
    end
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

  defp canonical_realpath(path) do
    expanded = Path.expand(path)

    case File.read_link(expanded) do
      {:ok, target} -> Path.expand(target, Path.dirname(expanded))
      _ -> expanded
    end
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
