defmodule SuperPi.Plugins.TranscriptLogger do
  @moduledoc """
  Dual-Write JSONL Transcript Logger & MCP/Plugin Manager (`SuperPi.Extension` behaviour).

  Implements:
  - Dual-writes `<appDataDir>/brain/<conversation-id>/.system_generated/logs/transcript.jsonl` (compact,
    truncating fields over `4_096` bytes and setting `truncated_fields`) and `transcript_full.jsonl`
    (untruncated).
  - Synchronizes transcript automatically after agent runs or on explicit calls.
  - Manages `<globalConfigDir>/mcp_config.json` (`add`, `remove`, `list`, `enable`, `disable`).
  - Manages `<globalConfigDir>/config.json` and `plugins/<name>/plugin.json` (`list`, `enable`, `disable`, `validate`).
  """

  use SuperPi.Extension

  def id, do: "transcript_logger"
  def name, do: "JSONL Dual-Write Transcript Logger"

  def description,
    do:
      "Dual-writes compact and full JSONL conversation transcripts and manages MCP configuration"

  alias SuperPi.Discovery
  alias SuperPi.Durable.Context

  @compact_limit_bytes 4_096

  @impl true
  def after_run(_summary, ctx) do
    if ctx[:conversation_id] do
      try do
        sync_transcript!(ctx.conversation_id)
      rescue
        _ -> :ok
      end
    end

    :accept
  end

  @doc """
  Exports the derived conversation history to `transcript.jsonl` (compact) and `transcript_full.jsonl`
  under `<appDataDir>/brain/<conversation_id>/.system_generated/logs/`.
  """
  def sync_transcript!(conversation_id, opts \\ []) do
    app_dir = Keyword.get(opts, :app_data_dir, Discovery.default_app_data_dir())

    logs_dir =
      Path.join([app_dir, "brain", to_string(conversation_id), ".system_generated", "logs"])

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

    compact_content = if compact_lines == [], do: "", else: Enum.join(compact_lines, "\n") <> "\n"
    full_content = if full_lines == [], do: "", else: Enum.join(full_lines, "\n") <> "\n"

    File.write!(compact_path, compact_content)
    File.write!(full_path, full_content)

    %{compact_path: compact_path, full_path: full_path, step_count: length(visible)}
  end

  @doc """
  The steps of a conversation as `sync_transcript!/2` writes them to `transcript.jsonl`: in order,
  each field cut at #{@compact_limit_bytes} bytes. Served as the MCP `superpi://conversation/{id}/transcript` resource.
  """
  @spec transcript_steps(integer()) :: [map()]
  def transcript_steps(conversation_id) do
    {visible, _} = Context.visible_entries_with_graph(conversation_id)

    visible
    |> Enum.with_index(1)
    |> Enum.map(fn {entry, idx} ->
      entry |> entry_to_transcript_step(idx) |> truncate_step_for_compact()
    end)
  end

  # --- MCP Server Management (`mcp ...`) ---

  def mcp_list(opts \\ []) do
    cfg_path = mcp_config_path(opts)
    raw_servers = read_json_map(cfg_path)["mcpServers"]
    servers = if is_map(raw_servers), do: raw_servers, else: %{}

    servers
    |> Enum.map(fn
      {name, spec} when is_map(spec) ->
        type =
          if Map.has_key?(spec, "url") or Map.has_key?(spec, "serverUrl"),
            do: "http",
            else: "stdio"

        status = if Map.get(spec, "disabled", false) == true, do: "disabled", else: "enabled"

        args_list =
          case Map.get(spec, "args") do
            list when is_list(list) -> Enum.map(list, &to_string/1)
            str when is_binary(str) and str != "" -> [str]
            _ -> []
          end

        cmd = to_string(Map.get(spec, "command", ""))
        parts = if cmd != "", do: [cmd | args_list], else: args_list
        target = Map.get(spec, "url") || Map.get(spec, "serverUrl") || Enum.join(parts, " ")

        %{name: to_string(name), type: type, status: status, target: String.trim(target)}

      {name, other} ->
        %{name: to_string(name), type: "unknown", status: "disabled", target: inspect(other)}
    end)
    |> Enum.sort_by(& &1.name)
  end

  @doc "Enabled MCP servers from `mcp_config.json` as `%{name => spec}`. Disabled entries are left out."
  def mcp_specs(opts \\ []) do
    case read_json_map(mcp_config_path(opts))["mcpServers"] do
      servers when is_map(servers) ->
        servers
        |> Enum.filter(fn {_name, spec} ->
          is_map(spec) and Map.get(spec, "disabled", false) != true
        end)
        |> Map.new()

      _ ->
        %{}
    end
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
    servers = Map.get(root, "mcpServers", %{})

    if Map.has_key?(servers, name) do
      write_json_map!(cfg_path, Map.put(root, "mcpServers", Map.delete(servers, name)))
      :ok
    else
      {:error, :not_found}
    end
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

  # --- Plugin Management (`plugin ...`) ---

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

  def plugin_set_enabled(plugin_id, enabled?, opts \\ [])
      when is_binary(plugin_id) and is_boolean(enabled?) do
    global_dir = Keyword.get(opts, :global_config_dir, Discovery.default_global_config_dir())
    cfg_path = Path.join(global_dir, "config.json")

    if Enum.any?(plugin_list(opts), &(&1.id == plugin_id)) do
      root = read_json_map(cfg_path)
      plugins = Map.get(root, "plugins", %{}) |> Map.put(plugin_id, %{"enabled" => enabled?})
      write_json_map!(cfg_path, Map.put(root, "plugins", plugins))
      :ok
    else
      {:error, :not_found}
    end
  end

  def plugin_validate(plugin_dir) when is_binary(plugin_dir) do
    manifest_path = Path.join(plugin_dir, "plugin.json")

    case File.read(manifest_path) do
      {:ok, raw} ->
        case Jason.decode(raw) do
          {:ok, map} when is_map(map) ->
            {:ok,
             %{valid: true, name: Map.get(map, "name", Path.basename(plugin_dir)), errors: []}}

          {:ok, _non_map} ->
            {:error, %{valid: false, errors: ["plugin.json must be a JSON object"]}}

          {:error, err} ->
            {:error, %{valid: false, errors: ["Invalid JSON in plugin.json: #{inspect(err)}"]}}
        end

      {:error, reason} ->
        {:error,
         %{valid: false, errors: ["Cannot read plugin.json in #{plugin_dir}: #{inspect(reason)}"]}}
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

    created_at =
      case Map.get(entry, :inserted_at) do
        %DateTime{} = dt -> DateTime.to_iso8601(dt)
        %NaiveDateTime{} = ndt -> DateTime.from_naive!(ndt, "Etc/UTC") |> DateTime.to_iso8601()
        _ -> DateTime.utc_now() |> DateTime.to_iso8601()
      end

    %{
      "step_index" => idx,
      "source" => source,
      "type" => type,
      "status" => "DONE",
      "created_at" => created_at,
      "content" => content_str
    }
  end

  defp truncate_step_for_compact(%{"content" => c} = step)
       when byte_size(c) > @compact_limit_bytes do
    truncated = safe_truncate_utf8(c, @compact_limit_bytes) <> "...[TRUNCATED]"

    step
    |> Map.put("content", truncated)
    |> Map.put("truncated_fields", ["content"])
  end

  defp truncate_step_for_compact(step), do: step

  defp safe_truncate_utf8(binary, max_bytes) when byte_size(binary) <= max_bytes, do: binary

  defp safe_truncate_utf8(binary, max_bytes) do
    part = binary_part(binary, 0, max_bytes)
    trim_invalid_utf8_tail(part)
  end

  defp trim_invalid_utf8_tail(""), do: ""

  defp trim_invalid_utf8_tail(binary) do
    if String.valid?(binary) do
      binary
    else
      trim_invalid_utf8_tail(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end

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
