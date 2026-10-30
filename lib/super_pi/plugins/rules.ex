defmodule SuperPi.Plugins.Rules do
  @moduledoc """
  Project & Agent Rules Plugin (`SuperPi.Extension` behaviour).

  Implements rule loading and injection semantics:
  - Walks up from workspace directories to the repository root discovering `AGENTS.md`, `GEMINI.md`,
    and `.agents/rules/*.md`, plus global config rules (`<global config>/AGENTS.md`).
  - Deduplicates all rules by canonical resolved path so a rule file is never injected twice.
  - Enforces the **Per-File Limit (`24,000` bytes)**, truncating cleanly on line boundaries when a rule
    file exceeds `24,000` bytes.
  - Enforces the **Aggregate Rules Budget (`20,000` tokens / `~80,000` bytes)**: rules within budget are
    inlined as `<RULE[path]>` blocks inside a `pi.system` section (`id: "user_rules"`); over-budget
    rules are demoted to file-path pointers so the agent can read them on demand.
  """

  use SuperPi.Extension

  def id, do: "rules"
  def name, do: "Agent & Project Rules Injector"

  def description,
    do: "Discovers and injects AGENTS.md, GEMINI.md, and rules within token budgets"

  alias SuperPi.Discovery

  @per_file_byte_limit 24_000
  @default_rules_token_budget 20_000

  @impl true
  def before_agent_start(agent_cfg, _ctx) do
    workspace_dirs = Map.get(agent_cfg, "workspacePaths", [File.cwd!()])
    global_dir = Map.get(agent_cfg, "globalConfigDir", Discovery.default_global_config_dir())
    token_budget = Map.get(agent_cfg, "rulesTokenBudget", @default_rules_token_budget)

    rule_paths = Discovery.discover_rule_files(workspace_dirs, global_config_dir: global_dir)
    rendered_rules = build_rules_section(rule_paths, token_budget)

    if rendered_rules == "" do
      {:ok, agent_cfg}
    else
      existing_sections =
        case Map.get(agent_cfg, "systemSections") do
          list when is_list(list) -> list
          _ -> [%{"id" => "core", "content" => "You are an intelligent AI assistant."}]
        end

      clean_sections =
        Enum.reject(existing_sections, &(&1["id"] in ["user_rules", "agy_user_rules"]))

      updated_sections = clean_sections ++ [%{"id" => "user_rules", "content" => rendered_rules}]

      {:ok, Map.put(agent_cfg, "systemSections", updated_sections)}
    end
  end

  @doc """
  Truncates raw rule text to `@per_file_byte_limit` (`24,000` bytes) on a line boundary.
  """
  def truncate_rule_to_limit(content, max_bytes \\ @per_file_byte_limit)
      when is_binary(content) do
    if byte_size(content) <= max_bytes do
      content
    else
      content
      |> String.split("\n")
      |> Enum.reduce_while({"", 0}, fn line, {acc, used} ->
        line_bytes = byte_size(line) + 1

        if used + line_bytes > max_bytes do
          {:halt, {acc <> "\n[... rule truncated at 24,000-byte limit ...]", used}}
        else
          next_acc = if acc == "", do: line, else: acc <> "\n" <> line
          {:cont, {next_acc, used + line_bytes}}
        end
      end)
      |> elem(0)
    end
  end

  @doc """
  Formats discovered rule files under `token_budget` (`20,000` tokens), demoting over-budget files
  to path pointers.
  """
  def build_rules_section(rule_paths, token_budget \\ @default_rules_token_budget)
      when is_list(rule_paths) do
    {blocks, _used_tokens} =
      Enum.reduce(rule_paths, {[], 0}, fn path, {acc, used_tok} ->
        case File.read(path) do
          {:ok, raw} ->
            capped = truncate_rule_to_limit(raw)
            est_tokens = max(div(byte_size(capped), 4), 1)

            if used_tok + est_tokens <= token_budget do
              block = "<RULE[#{path}]>\n#{capped}\n</RULE[#{path}]>"
              {acc ++ [block], used_tok + est_tokens}
            else
              demoted =
                "<RULE_POINTER[#{path}] (Demoted due to 20,000-token rules budget; read file on demand) />"

              {acc ++ [demoted], used_tok}
            end

          _ ->
            {acc, used_tok}
        end
      end)

    Enum.join(blocks, "\n")
  end
end
