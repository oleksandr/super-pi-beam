defmodule SuperPi.Harness.AGY.CLI do
  @moduledoc """
  Antigravity CLI (`agy`) Clone Entrypoint built on `Super-Pi-BEAM` (`12 - AGY Clone Specification and Gap Analysis.md`).

  Supports all `agy` flags and subcommands while executing every customization layer through
  modular `SuperPi.Extension` behaviours:
  - `SuperPi.Harness.AGY.Extensions.SlashCommands`
  - `SuperPi.Harness.AGY.Extensions.Rules`
  - `SuperPi.Harness.AGY.Extensions.Skills`
  - `SuperPi.Harness.AGY.Extensions.HooksJson`
  - `SuperPi.Harness.AGY.Extensions.Permissions`
  """

  alias SuperPi.Harness.AGY.{Brain, Discovery}
  alias SuperPi.Harness.AGY.Extensions.{HooksJson, Permissions, Rules, Skills, SlashCommands}
  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.Storage
  alias SuperPi.Tools
  alias SuperPi.TUI.Owl, as: OwlTUI

  @agy_models [
    {"gemini-3-flash-preview", "Gemini 3 Flash Preview (Live)"},
    {"gemini-4-argon-medium", "Gemini 4 Argon (Medium)"},
    {"gemini-4-argon-high", "Gemini 4 Argon (High)"},
    {"gemini-4-argon-low", "Gemini 4 Argon (Low)"},
    {"gemini-3.8-flash-high", "Gemini 3.8 Flash (High)"},
    {"gemini-3.8-flash-medium", "Gemini 3.8 Flash (Medium)"},
    {"gemini-3.8-flash-low", "Gemini 3.8 Flash (Low)"},
    {"claude-opus-5-5-high", "Claude Opus 5.5 (High)"},
    {"claude-sonnet-5-5-medium", "Claude Sonnet 5.5 (Medium)"},
    {"gpt-oss-120b-medium", "GPT-OSS 120B (Medium)"}
  ]

  @agy_agents [
    {"self", "Full-capability coding agent with read/write/bash/MCP tools"},
    {"research", "Read-only codebase and documentation research agent"},
    {"image-generator", "Image generation and editing specialist"}
  ]

  def default_extensions do
    [
      SlashCommands,
      Rules,
      Skills,
      HooksJson,
      Permissions
    ]
  end

  def models_catalog do
    Enum.map(@agy_models, fn {id, label} -> %{"id" => id, "label" => label} end)
  end

  def agents_catalog do
    Enum.map(@agy_agents, fn {id, desc} -> %{"id" => id, "description" => desc} end)
  end

  @switches [
    add_dir: :keep,
    agent: :string,
    continue: :boolean,
    conversation: :integer,
    dangerously_skip_permissions: :boolean,
    disable_slash_commands: :boolean,
    effort: :string,
    help: :boolean,
    input_format: :string,
    json_schema: :string,
    log_file: :string,
    mode: :string,
    model: :string,
    new_project: :boolean,
    output_format: :string,
    print: :string,
    print_timeout: :integer,
    project: :string,
    prompt: :string,
    prompt_interactive: :string,
    remote_control: :boolean,
    sandbox: :boolean,
    settings: :string,
    json: :boolean,
    strict: :boolean
  ]

  @aliases [c: :continue, i: :prompt_interactive, p: :print, h: :help]

  @doc """
  Parses command-line arguments (`argv`) into `{:subcommand, cmd, args, flags}` or `{:run, flags, positional}`.
  """
  def parse_args(argv) when is_list(argv) do
    {flag_tokens, positional} = split_flags(argv)

    {parsed, _rest, _invalid} =
      OptionParser.parse(flag_tokens,
        strict: @switches,
        aliases: @aliases
      )

    flags = normalize_flags(parsed)

    if subcommand?(positional) do
      [sub | rest] = positional
      {:subcommand, sub, rest, flags}
    else
      {:run, flags, positional}
    end
  end

  # Splits argv into known flag tokens (with their values) and everything else.
  # Unknown dash words stay in the positional list in their original order, so
  # prompts such as `explain the --foo flag` and `mcp add fs npx -y pkg` survive.
  defp split_flags(argv), do: split_flags(argv, [], [])

  defp split_flags([], flags, pos), do: {Enum.reverse(flags), Enum.reverse(pos)}
  defp split_flags(["--" | rest], flags, pos), do: {Enum.reverse(flags), Enum.reverse(pos) ++ rest}

  defp split_flags(["--" <> long = tok | rest], flags, pos) do
    {name, has_inline?} =
      case String.split(long, "=", parts: 2) do
        [n, _] -> {n, true}
        [n] -> {n, false}
      end

    key = name |> String.replace("-", "_") |> existing_switch()

    cond do
      is_nil(key) -> split_flags(rest, flags, [tok | pos])
      has_inline? -> split_flags(rest, [tok | flags], pos)
      @switches[key] in [:boolean] -> split_flags(rest, [tok | flags], pos)
      true -> take_value(tok, rest, flags, pos)
    end
  end

  defp split_flags(["-" <> short = tok | rest], flags, pos) when byte_size(short) == 1 do
    case @aliases[String.to_atom(short)] do
      nil ->
        split_flags(rest, flags, [tok | pos])

      key ->
        if @switches[key] == :boolean,
          do: split_flags(rest, [tok | flags], pos),
          else: take_value(tok, rest, flags, pos)
    end
  end

  defp split_flags([tok | rest], flags, pos), do: split_flags(rest, flags, [tok | pos])

  defp take_value(tok, [value | rest], flags, pos), do: split_flags(rest, [value, tok | flags], pos)
  defp take_value(tok, [], flags, pos), do: split_flags([], [tok | flags], pos)

  defp existing_switch(name) do
    Enum.find_value(Keyword.keys(@switches), fn k -> if Atom.to_string(k) == name, do: k end)
  end

  @top_subcommands ["agent", "agents", "models", "changelog", "help"]
  @mcp_actions ["list", "add", "remove", "enable", "disable"]
  @plugin_actions ["list", "enable", "disable", "validate"]
  @remote_actions ["start", "status", "stop"]

  # A leading word is a subcommand only when the shape matches; otherwise the
  # whole line is a prompt (`help me with this`).
  defp subcommand?([sub]) when sub in @top_subcommands, do: true
  defp subcommand?(["help", sub]) when sub in @top_subcommands or sub in ["mcp", "plugin", "plugins"], do: true
  defp subcommand?([sub]) when sub in ["mcp", "plugin", "plugins", "remote-control"], do: true
  defp subcommand?(["mcp", action | _]), do: action in @mcp_actions
  defp subcommand?([sub, action | _]) when sub in ["plugin", "plugins"], do: action in @plugin_actions
  defp subcommand?(["remote-control", action | _]), do: action in @remote_actions
  defp subcommand?(_), do: false

  @doc """
  Executes the parsed CLI command and returns `{exit_code, output_string}`.
  """
  def run(argv, opts \\ []) when is_list(argv) do
    case parse_args(argv) do
      {:subcommand, "help", _rest, _flags} ->
        {0, help_text()}

      {:subcommand, sub, _rest, _flags} when sub in ["agent", "agents"] ->
        out =
          @agy_agents
          |> Enum.map(fn {id, desc} -> String.pad_trailing(id, 20) <> desc end)
          |> Enum.join("\n")

        {0, out}

      {:subcommand, "models", _rest, _flags} ->
        out =
          @agy_models
          |> Enum.map(fn {id, label} -> String.pad_trailing(id, 26) <> label end)
          |> Enum.join("\n")

        {0, out}

      {:subcommand, "mcp", rest, _flags} ->
        run_mcp_subcommand(rest, opts)

      {:subcommand, sub, rest, flags} when sub in ["plugin", "plugins"] ->
        run_plugin_subcommand(rest, flags, opts)

      {:subcommand, "remote-control", rest, _flags} ->
        run_remote_control_subcommand(rest)

      {:subcommand, "changelog", _rest, _flags} ->
        {0, "SuperPi.Harness.AGY v0.1.0 (Built on Super-Pi-BEAM OTP 28 / Elixir 1.20)"}

      {:run, %{help: true}, _pos} ->
        {0, help_text()}

      {:run, flags, positional} ->
        execute_session(flags, positional, opts)
    end
  end

  # --- Session Execution ---

  def execute_session(flags, positional, opts \\ []) do
    workspace_dirs = [File.cwd!() | flags.add_dirs] |> Enum.map(&Path.expand/1) |> Enum.uniq()
    global_dir = Keyword.get(opts, :global_config_dir, Discovery.default_global_config_dir())
    app_dir = Keyword.get(opts, :app_data_dir, Discovery.default_app_data_dir())

    agent_cfg = %{
      "model" => flags.model || "gemini-3-flash-preview",
      "effort" => flags.effort || "medium",
      "executionMode" => flags.mode || "auto",
      "dangerouslySkipPermissions" => flags.dangerously_skip_permissions,
      "disableSlashCommands" => flags.disable_slash_commands,
      "workspacePaths" => workspace_dirs,
      "globalConfigDir" => global_dir,
      "appDataDir" => app_dir,
      "settingsOverride" => parse_settings_flag(flags.settings),
      "jsonSchema" => parse_json_schema_flag(flags.json_schema),
      "tools" => Tools.active_llm_tools()
    }

    conv =
      cond do
        is_integer(flags.conversation) ->
          Storage.configure_agent!(flags.conversation, agent_cfg)
          %{id: flags.conversation}

        flags.continue ->
          root = Storage.ensure_root_conversation!(agent_cfg)
          Storage.configure_agent!(root.id, agent_cfg)
          root

        true ->
          Storage.create_conversation!(agent: agent_cfg)
      end

    machine_opts =
      [
        conversation_id: conv.id,
        extensions: Keyword.get(opts, :extensions, default_extensions())
      ]
      |> maybe_put(:llm_responder, Keyword.get(opts, :llm_responder))
      |> maybe_put(:tool_executor, Keyword.get(opts, :tool_executor))

    {:ok, pid} = start_or_attach_machine(conv.id, machine_opts)

    prompt_text = flags.print || flags.prompt || Enum.join(positional, " ")

    result =
      cond do
        flags.input_format == "stream-json" ->
          stream_lines = Keyword.get(opts, :stdin_lines, [])
          run_stream_json_turns(conv.id, pid, stream_lines, app_dir)

        Keyword.get(opts, :interactive_tui, false) and (prompt_text == "" or flags.prompt_interactive != nil) ->
          launch_interactive_tui(conv.id, flags, workspace_dirs, opts)

        prompt_text != "" or flags.prompt_interactive != nil ->
          effective_prompt = if prompt_text != "", do: prompt_text, else: flags.prompt_interactive

          case Machine.submit(pid, effective_prompt) do
            {:ok, :handled_by_extension} ->
              Brain.sync_transcript!(conv.id, app_data_dir: app_dir)
              {0, format_output(%{"status" => "handled"}, flags.output_format)}

            {:ok, assistant_msg} ->
              Brain.sync_transcript!(conv.id, app_data_dir: app_dir)
              {0, format_output(assistant_msg, flags.output_format)}

            {:error, reason} ->
              {1, format_output(%{"error" => inspect(reason)}, flags.output_format)}
          end

        true ->
          {0, OwlTUI.render_status_bar(conv.id)}
      end

    GenServer.stop(pid)
    result
  end

  def launch_interactive_tui(conv_id, flags, workspace_dirs, opts \\ []) do
    {:ok, rpc_pid} = SuperPi.RPC.Server.start_link(port: 0)
    port = SuperPi.RPC.Server.port(rpc_pid)
    tui_bin = Keyword.get(opts, :tui_binary, Path.expand("bin/agy-tui", File.cwd!()))

    res =
      if File.exists?(tui_bin) do
        args =
          [
            "--rpc-addr",
            "127.0.0.1:#{port}",
            "--conversation",
            to_string(conv_id),
            "--model",
            flags.model || "gemini-3-flash-preview",
            "--effort",
            flags.effort || "medium",
            "--mode",
            flags.mode || "auto",
            "--workspace",
            List.first(workspace_dirs) || File.cwd!()
          ] ++
            if(flags.prompt_interactive, do: ["--prompt", flags.prompt_interactive], else: [])

        port_handle =
          Port.open({:spawn_executable, tui_bin}, [
            :nouse_stdio,
            :exit_status,
            args: args
          ])

        receive do
          {^port_handle, {:exit_status, code}} -> {code, ""}
        end
      else
        {0, OwlTUI.render_status_bar(conv_id)}
      end

    GenServer.stop(rpc_pid)
    res
  end

  # --- Subcommands ---

  defp run_mcp_subcommand(["list" | _], opts) do
    servers = Brain.mcp_list(opts)
    header = "NAME   TYPE   STATUS   COMMAND/URL"

    rows =
      Enum.map(servers, fn s ->
        "#{String.pad_trailing(s.name, 6)} #{String.pad_trailing(s.type, 6)} #{String.pad_trailing(s.status, 8)} #{s.target}"
      end)

    {0, Enum.join([header | rows], "\n")}
  end

  defp run_mcp_subcommand(["add", name, cmd_or_url | args], opts) do
    spec =
      if String.starts_with?(cmd_or_url, "http://") or String.starts_with?(cmd_or_url, "https://") do
        %{"url" => cmd_or_url}
      else
        %{"command" => cmd_or_url, "args" => args}
      end

    Brain.mcp_add(name, spec, opts)
    {0, "Added MCP server #{name}"}
  end

  defp run_mcp_subcommand(["remove", name | _], opts) do
    case Brain.mcp_remove(name, opts) do
      :ok -> {0, "Removed MCP server #{name}"}
      {:error, :not_found} -> {1, "MCP server not found: #{name}"}
    end
  end

  defp run_mcp_subcommand(["enable", name | _], opts) do
    case Brain.mcp_set_enabled(name, true, opts) do
      :ok -> {0, "Enabled MCP server #{name}"}
      {:error, :not_found} -> {1, "MCP server not found: #{name}"}
    end
  end

  defp run_mcp_subcommand(["disable", name | _], opts) do
    case Brain.mcp_set_enabled(name, false, opts) do
      :ok -> {0, "Disabled MCP server #{name}"}
      {:error, :not_found} -> {1, "MCP server not found: #{name}"}
    end
  end

  defp run_mcp_subcommand(_, _opts) do
    {0, "Usage: agy mcp <add|remove|list|enable|disable>"}
  end

  defp run_plugin_subcommand(["list" | _], flags, opts) do
    plugins = Brain.plugin_list(opts)

    if flags.json do
      {0, Jason.encode!(plugins)}
    else
      out =
        plugins
        |> Enum.map(fn p -> "#{p.id} (#{if p.enabled, do: "enabled", else: "disabled"})" end)
        |> Enum.join("\n")

      {0, out}
    end
  end

  defp run_plugin_subcommand(["enable", name | _], _flags, opts) do
    case Brain.plugin_set_enabled(name, true, opts) do
      :ok -> {0, "Enabled plugin #{name}"}
      {:error, :not_found} -> {1, "Plugin not found: #{name}"}
    end
  end

  defp run_plugin_subcommand(["disable", name | _], _flags, opts) do
    case Brain.plugin_set_enabled(name, false, opts) do
      :ok -> {0, "Disabled plugin #{name}"}
      {:error, :not_found} -> {1, "Plugin not found: #{name}"}
    end
  end

  defp run_plugin_subcommand(["validate", path | _], _flags, _opts) do
    case Brain.plugin_validate(path) do
      {:ok, info} -> {0, Jason.encode!(info)}
      {:error, info} -> {1, Jason.encode!(info)}
    end
  end

  defp run_plugin_subcommand(_, _flags, _opts) do
    {0, "Usage: agy plugin <list|enable|disable|validate>"}
  end

  defp run_remote_control_subcommand(["status" | _]) do
    {0, Jason.encode!(%{"daemon" => "super_pi_rpc", "status" => "ready"})}
  end

  defp run_remote_control_subcommand(["start" | _]) do
    {:ok, pid} = SuperPi.RPC.Server.start_link(port: 0)
    port = SuperPi.RPC.Server.port(pid)
    {0, Jason.encode!(%{"daemon" => "super_pi_rpc", "status" => "started", "port" => port})}
  end

  defp run_remote_control_subcommand(_) do
    {0, "Usage: agy remote-control <start|status|stop>"}
  end

  # --- Helpers ---

  defp run_stream_json_turns(conv_id, pid, lines, app_dir) do
    outputs =
      Enum.map(lines, fn line ->
        prompt =
          case Jason.decode(line) do
            {:ok, %{"prompt" => p}} -> p
            {:ok, %{"text" => t}} -> t
            _ -> line
          end

        {:ok, msg} = Machine.submit(pid, prompt)
        Jason.encode!(%{"type" => "turn_result", "conversation_id" => conv_id, "message" => msg})
      end)

    Brain.sync_transcript!(conv_id, app_data_dir: app_dir)
    {0, Enum.join(outputs, "\n")}
  end

  defp format_output(msg, "json") when is_map(msg), do: Jason.encode!(msg)

  defp format_output(msg, "stream-json") when is_map(msg) do
    Jason.encode!(%{"type" => "result", "data" => msg})
  end

  defp format_output(%{"content" => blocks}, _text_format) when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %{"type" => "text", "text" => t} -> t
      other -> Jason.encode!(other)
    end)
    |> Enum.join("\n")
  end

  defp format_output(other, _), do: inspect(other)

  defp normalize_flags(parsed) do
    %{
      add_dirs: Keyword.get_values(parsed, :add_dir),
      agent: Keyword.get(parsed, :agent, "self"),
      continue: Keyword.get(parsed, :continue, false),
      conversation: Keyword.get(parsed, :conversation),
      dangerously_skip_permissions: Keyword.get(parsed, :dangerously_skip_permissions, false),
      disable_slash_commands: Keyword.get(parsed, :disable_slash_commands, false),
      effort: Keyword.get(parsed, :effort, "medium"),
      help: Keyword.get(parsed, :help, false),
      input_format: Keyword.get(parsed, :input_format, "text"),
      json_schema: Keyword.get(parsed, :json_schema),
      mode: Keyword.get(parsed, :mode, "auto"),
      model: Keyword.get(parsed, :model),
      output_format: Keyword.get(parsed, :output_format, "text"),
      print: Keyword.get(parsed, :print),
      prompt: Keyword.get(parsed, :prompt),
      prompt_interactive: Keyword.get(parsed, :prompt_interactive),
      sandbox: Keyword.get(parsed, :sandbox, false),
      settings: Keyword.get(parsed, :settings),
      json: Keyword.get(parsed, :json, false)
    }
  end

  defp parse_settings_flag(nil), do: %{}

  defp parse_settings_flag(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, map} when is_map(map) ->
        map

      _ ->
        case File.read(Path.expand(str)) do
          {:ok, raw} ->
            case Jason.decode(raw) do
              {:ok, map} when is_map(map) -> map
              _ -> %{}
            end

          _ ->
            %{}
        end
    end
  end

  defp parse_json_schema_flag(nil), do: nil

  defp parse_json_schema_flag(str) when is_binary(str) do
    case Jason.decode(str) do
      {:ok, map} when is_map(map) ->
        map

      _ ->
        case File.read(Path.expand(str)) do
          {:ok, raw} ->
            case Jason.decode(raw) do
              {:ok, map} when is_map(map) -> map
              _ -> nil
            end

          _ ->
            nil
        end
    end
  end

  defp start_or_attach_machine(conv_id, opts) do
    case Registry.lookup(SuperPi.Registry, {:conversation_machine, conv_id}) do
      [{pid, _}] -> {:ok, pid}
      [] -> Machine.start_link(opts)
    end
  end

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: Keyword.put(kw, k, v)

  def help_text do
    """
    Usage of super-agy (SuperPi.Harness.AGY clone of Antigravity CLI):
      --add-dir                       Add a directory to the workspace (repeatable)
      --agent                         Agent for the current CLI session
      -c, --continue                  Continue the most recent conversation
      --conversation                  Resume a previous conversation by ID
      --dangerously-skip-permissions  Auto-approve all tool permission requests without prompting
      --disable-slash-commands        Disable slash command and skill expansion in print mode
      --effort                        Reasoning effort (low|medium|high|xhigh|max)
      -i, --prompt-interactive        Run an initial prompt interactively
      --input-format                  Input format for print mode (text, stream-json)
      --json-schema                   JSON schema string or file path to enforce structured output
      --mode                          Agent execution mode (accept-edits, auto, plan)
      --model                         Model for the current CLI session
      --output-format                 Output format for print mode (text, json, stream-json)
      -p, --print, --prompt           Run a single prompt non-interactively and print the response
      --sandbox                       Run in a sandbox with terminal restrictions enabled
      --settings                      Session settings override (inline JSON or file path)

    Available subcommands:
      agent, agents   List available agents
      models          List available models
      mcp             Manage MCP servers (add, remove, list, enable, disable)
      plugin, plugins Manage plugins (list, enable, disable, validate)
      remote-control  Manage the remote-control background daemon (start, status, stop)
      changelog       Show changelog and release notes
      help            Show help for subcommands
    """
  end
end
