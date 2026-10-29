defmodule SuperPi.AGY.Brain do
  @moduledoc """
  Antigravity Brain, Dual-Write JSONL Transcript Exporter, MCP Manager, & Plugin Manager.

  Implements exact `agy` directory and file contracts:
  - Dual-writes `<appDataDir>/brain/<conversation-id>/.system_generated/logs/transcript.jsonl` (compact,
    truncating fields over `4_096` bytes and setting `truncated_fields`) and `transcript_full.jsonl`
    (untruncated).
  - Manages `<globalConfigDir>/mcp_config.json` (`add`, `remove`, `list`, `enable`, `disable`).
  - Manages `<globalConfigDir>/config.json` and `plugins/<name>/plugin.json` (`list`, `enable`, `disable`, `validate`).
  """

  alias SuperPi.AGY.Discovery
  alias SuperPi.Durable.Context

  @compact_limit_bytes 4_096

  @doc """
  Exports the derived conversation history to `transcript.jsonl` (compact) and `transcript_full.jsonl`
  under `<appDataDir>/brain/<conversation_id>/.system_generated/logs/`.
  """
  def sync_transcript!(conversation_id, opts \\ []) do
    app_dir = Keyword.get(opts, :app_data_dir, Discovery.default_app_data_dir())
    logs_dir = Path.join([app_dir, "brain", to_string(conversation_id), ".system_generated", "logs"])
    File.mkdir_p!(logs_dir)

    compact_path = Path.join(logs_dir, "transcript.jsonl")
    full_path = Path.join(logs_dir, "transcript_full.jsonl")

    {visible, _} = Context.visible_entries_with_graph(conversation_id)

    {compact_lines, full_lines} =
      visible
      |> Enum.with_index(1)
      |> Enum.map(fn {entry, idx} ->
        full_step = entry_to_transcript_step(entry, idx)
        compact_step = truncate_step_for_compact(full_step)
        {Jason.encode!(compact_step), Jason.encode!(full_step)}
      end)
      |> Enum.unzip()

    File.write!(compact_path, Enum.join(compact_lines, "\n") <> "\n")
    File.write!(full_path, Enum.join(full_lines, "\n") <> "\n")

    %{compact_path: compact_path, full_path: full_path, step_count: length(visible)}
  end

  # --- MCP Server Management (`agy mcp ...`) ---

  def mcp_list(opts \\ []) do
    cfg_path = mcp_config_path(opts)
    servers = read_json_map(cfg_path)["mcpServers"] || %{}

    Enum.map(servers, fn {name, spec} ->
      type = if Map.has_key?(spec, "url") or Map.has_key?(spec, "serverUrl"), do: "http", else: "stdio"
      status = if Map.get(spec, "disabled", false) == true, do: "disabled", else: "enabled"
      target = Map.get(spec, "url") || Map.get(spec, "serverUrl") || Enum.join([Map.get(spec, "command", "") | Map.get(spec, "args", [])], " ")
      %{name: name, type: type, status: status, target: String.trim(target)}
    end)
    |> Enum.sort_by(& &1.name)
  end

  def mcp_add(name, spec, opts \\ []) when is_binary(name) and is_map(spec) do
    cfg_path = mcp_config_path(opts)
    root = read_json_map(cfg_path)
    servers = Map.get(root, "mcpServers", %{}) |> Map.put(name, spec)
    write_json_map!(cfg_path, Map.put(root, "mcpServers", servers))
  end

  def mcp_remove(name, opts \\ []) when is_binary(name) do
    cfg_path = mcp_config_path(opts)
    root = read_json_map(cfg_path)
    servers = Map.get(root, "mcpServers", %{}) |> Map.delete(name)
    write_json_map!(cfg_path, Map.put(root, "mcpServers", servers))
  end

  def mcp_set_enabled(name, enabled?, opts \\ []) when is_binary(name) and is_boolean(enabled?) do
    cfg_path = mcp_config_path(opts)
    root = read_json_map(cfg_path)
    servers = Map.get(root, "mcpServers", %{})

    case Map.get(servers, name) do
      nil ->
        {:error, :not_found}

      spec ->
        updated = Map.put(spec, "disabled", not enabled?)
        write_json_map!(cfg_path, Map.put(root, "mcpServers", Map.put(servers, name, updated)))
        :ok
    end
  end

  # --- Plugin Management (`agy plugin ...`) ---

  def plugin_list(opts \\ []) do
    global_dir = Keyword.get(opts, :global_config_dir, Discovery.default_global_config_dir())
    plugins_dir = Path.join(global_dir, "plugins")
    config_map = read_json_map(Path.join(global_dir, "config.json"))
    overrides = Map.get(config_map, "plugins", %{})

    case File.ls(plugins_dir) do
      {:ok, dirs} ->
        dirs
        |> Enum.sort()
        |> Enum.flat_map(fn d ->
          manifest_path = Path.join([plugins_dir, d, "plugin.json"])

          if File.regular?(manifest_path) do
            manifest = read_json_map(manifest_path)
            default_enabled = Map.get(manifest, "disabled", false) != true
            enabled = get_in(overrides, [d, "enabled"])

            effective_enabled =
              if is_boolean(enabled), do: enabled, else: default_enabled

            [
              %{
                id: d,
                name: Map.get(manifest, "name", d),
                enabled: effective_enabled,
                path: Path.join(plugins_dir, d)
              }
            ]
          else
            []
          end
        end)

      _ ->
        []
    end
  end

  def plugin_set_enabled(plugin_id, enabled?, opts \\ []) when is_binary(plugin_id) and is_boolean(enabled?) do
    global_dir = Keyword.get(opts, :global_config_dir, Discovery.default_global_config_dir())
    cfg_path = Path.join(global_dir, "config.json")
    root = read_json_map(cfg_path)
    plugins = Map.get(root, "plugins", %{}) |> Map.put(plugin_id, %{"enabled" => enabled?})
    write_json_map!(cfg_path, Map.put(root, "plugins", plugins))
  end

  def plugin_validate(plugin_dir) when is_binary(plugin_dir) do
    manifest_path = Path.join(plugin_dir, "plugin.json")

    if File.regular?(manifest_path) do
      case File.read(manifest_path) |> elem(1) |> Jason.decode() do
        {:ok, map} when is_map(map) ->
          {:ok, %{valid: true, name: Map.get(map, "name", Path.basename(plugin_dir)), errors: []}}

        {:error, err} ->
          {:error, %{valid: false, errors: ["Invalid JSON in plugin.json: #{inspect(err)}"]}}
      end
    else
      {:error, %{valid: false, errors: ["Missing plugin.json in #{plugin_dir}"]}}
    end
  end

  # --- Helpers ---

  defp entry_to_transcript_step(entry, idx) do
    role = get_in(entry.data, ["role"]) || "system"

    {source, type} =
      case role do
        "user" -> {"USER_EXPLICIT", "USER_INPUT"}
        "assistant" -> {"MODEL", "PLANNER_RESPONSE"}
        "tool" -> {"SYSTEM", "TOOL_RESPONSE"}
        _ -> {"SYSTEM", entry.kind}
      end

    content_str =
      case entry.data["content"] do
        list when is_list(list) -> Jason.encode!(list)
        bin when is_binary(bin) -> bin
        other -> Jason.encode!(other || entry.data)
      end

    %{
      "step_index" => idx,
      "source" => source,
      "type" => type,
      "status" => "DONE",
      "created_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "content" => content_str
    }
  end

  defp truncate_step_for_compact(%{"content" => c} = step) when byte_size(c) > @compact_limit_bytes do
    truncated = binary_part(c, 0, @compact_limit_bytes) <> "...[TRUNCATED]"

    step
    |> Map.put("content", truncated)
    |> Map.put("truncated_fields", ["content"])
  end

  defp truncate_step_for_compact(step), do: step

  defp mcp_config_path(opts) do
    global_dir = Keyword.get(opts, :global_config_dir, Discovery.default_global_config_dir())
    Path.join(global_dir, "mcp_config.json")
  end

  defp read_json_map(path) do
    case File.read(path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, map} when is_map(map) -> map
          _ -> %{}
        end

      _ ->
        %{}
    end
  end

  defp write_json_map!(path, map) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map, pretty: true) <> "\n")
  end
end
