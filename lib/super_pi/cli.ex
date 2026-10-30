defmodule SuperPi.CLI do
  @moduledoc """
  Unified Command-Line Interface for Super-Pi-BEAM.

  Provides a single, standardized CLI for all agent harnesses:
  - Supports `--harness <id>` (`workspace`, `default`, `fast`, `auto`, `interactive`, `planner`).
  - Supports non-interactive `-p` / `--prompt` / `--print` and streaming turns (`--input-format stream-json`).
  - Supports conversation continuation (`-c`, `--continue`) and resumption (`--conversation <id>`).
  - Unified subcommands for `harnesses`, `models`, `agents`, `mcp`, `plugins`, `remote-control`, and `session`.
  - Guarantees clean process lifecycle management with synchronous registry unregistration on shutdown.
  """

  alias SuperPi.Conversation.Machine
  alias SuperPi.Discovery
  alias SuperPi.Durable.Storage
  alias SuperPi.Harness
  alias SuperPi.Plugins.TranscriptLogger
  alias SuperPi.TUI.Owl, as: OwlTUI
  alias SuperPi.Tools

  @agents [
    {"self", "Full-capability coding agent with read/write/bash/MCP tools"},
    {"research", "Read-only codebase and documentation research agent"},
    {"image-generator", "Image generation and editing specialist"}
  ]

  @switches [
    add_dir: :keep,
    agent: :string,
    continue: :boolean,
    conversation: :integer,
    dangerously_skip_permissions: :boolean,
    disable_slash_commands: :boolean,
    effort: :string,
    harness: :string,
    help: :boolean,
    input_format: :string,
    json: :boolean,
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
    strict: :boolean
  ]

  @aliases [
    c: :continue,
    H: :harness,
    h: :help,
    i: :prompt_interactive,
    p: :print
  ]

  def default_extensions do
    Harness.Workspace.extensions()
  end

  def models_catalog do
    SuperPi.AI.Providers.catalog()
  end

  def agents_catalog do
    Enum.map(@agents, fn {id, desc} -> %{"id" => id, "description" => desc} end)
  end

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

  @top_subcommands ["agent", "agents", "models", "harness", "harnesses", "changelog", "help", "chat"]
  @mcp_actions ["list", "add", "remove", "enable", "disable"]
  @plugin_actions ["list", "enable", "disable", "validate"]
  @remote_actions ["start", "status", "stop"]

  defp subcommand?([sub]) when sub in @top_subcommands, do: true
  defp subcommand?(["run" | _]), do: true
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
          @agents
          |> Enum.map(fn {id, desc} -> String.pad_trailing(id, 20) <> desc end)
          |> Enum.join("\n")

        {0, out}

      {:subcommand, "models", _rest, _flags} ->
        out =
          SuperPi.AI.Providers.catalog()
          |> Enum.map(fn m ->
            note = if m["available"], do: "", else: "  [#{m["provider"]}: not configured]"
            String.pad_trailing(m["id"], 26) <> m["label"] <> note
          end)
          |> Enum.join("\n")

        {0, out}

      {:subcommand, sub, _rest, _flags} when sub in ["harness", "harnesses"] ->
        harnesses = Harness.list()
        id_w = harnesses |> Enum.map(&String.length(&1.id())) |> Enum.max(fn -> 0 end) |> max(10) |> Kernel.+(2)
        name_w = harnesses |> Enum.map(&String.length(&1.name())) |> Enum.max(fn -> 0 end) |> max(4) |> Kernel.+(2)
        header = String.pad_trailing("HARNESS ID", id_w) <> String.pad_trailing("NAME", name_w) <> "DESCRIPTION"
        sep = String.duplicate("-", String.length(header) + 20)

        rows =
          Enum.map(harnesses, fn mod ->
            String.pad_trailing(mod.id(), id_w) <> String.pad_trailing(mod.name(), name_w) <> mod.description()
          end)

        {0, Enum.join([header, sep | rows], "\n")}

      {:subcommand, "mcp", rest, _flags} ->
        run_mcp_subcommand(rest, opts)

      {:subcommand, sub, rest, flags} when sub in ["plugin", "plugins"] ->
        run_plugin_subcommand(rest, flags, opts)

      {:subcommand, "remote-control", rest, _flags} ->
        run_remote_control_subcommand(rest)

      {:subcommand, "run", rest, flags} ->
        case Enum.join(rest, " ") do
          "" -> execute_session(%{flags | print: read_stdin_prompt(opts)}, [], opts)
          prompt -> execute_session(%{flags | print: prompt}, [], opts)
        end

      {:subcommand, "chat", _rest, flags} ->
        execute_session(flags, [], Keyword.put(opts, :chat, true))

      {:subcommand, "changelog", _rest, _flags} ->
        {0, "Super-Pi-BEAM v0.1.0 (OTP 28 / Elixir 1.20)"}

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

    case resolve_harness(flags, opts) do
      {:ok, harness_mod} ->
        start_session(flags, positional, opts, harness_mod, workspace_dirs, global_dir, app_dir)

      {:error, message} ->
        {1, message}
    end
  end

  defp resolve_harness(flags, opts) do
    case flags.harness || Keyword.get(opts, :harness) do
      nil ->
        {:ok, Harness.default()}

      name ->
        case Harness.fetch(name) do
          {:ok, mod} -> {:ok, mod}
          {:error, _} -> {:error, "Unknown harness: #{name}. Run `super-pi harnesses` to list them."}
        end
    end
  end

  defp start_session(flags, positional, opts, harness_mod, workspace_dirs, global_dir, app_dir) do
    base_agent_defaults = harness_mod.agent_defaults(
      model: flags.model || "gemini-3-flash-preview",
      effort: flags.effort || "medium",
      mode: flags.mode || "auto",
      workspace_paths: workspace_dirs
    )

    agent_cfg =
      base_agent_defaults
      |> Map.merge(%{
        "dangerouslySkipPermissions" => flags.dangerously_skip_permissions,
        "disableSlashCommands" => flags.disable_slash_commands,
        "workspacePaths" => workspace_dirs,
        "globalConfigDir" => global_dir,
        "appDataDir" => app_dir,
        "settingsOverride" => parse_settings_flag(flags.settings),
        "jsonSchema" => parse_json_schema_flag(flags.json_schema),
        "agent" => flags.agent,
        "tools" => tools_for_agent(flags.agent)
      })
      |> maybe_override("model", flags.model)
      |> maybe_override("effort", flags.effort)
      |> maybe_override("executionMode", flags.mode)

    conv =
      cond do
        is_integer(flags.conversation) ->
          Storage.configure_agent!(flags.conversation, agent_cfg)
          %{id: flags.conversation}

        flags.continue ->
          case Storage.latest_conversation() do
            nil ->
              Storage.create_conversation!(agent: agent_cfg)

            latest ->
              Storage.configure_agent!(latest.id, agent_cfg)
              latest
          end

        true ->
          Storage.create_conversation!(agent: agent_cfg)
      end

    active_extensions = Keyword.get(opts, :extensions, harness_mod.extensions())

    machine_opts =
      [
        conversation_id: conv.id,
        extensions: active_extensions
      ]
      |> maybe_put(:llm_responder, Keyword.get(opts, :llm_responder))
      |> maybe_put(:tool_executor, Keyword.get(opts, :tool_executor))

    {:ok, pid, started?} = start_or_attach_machine(conv.id, machine_opts)

    try do
      run_session(conv, pid, flags, positional, workspace_dirs, app_dir, opts)
    after
      if started? and Process.alive?(pid), do: stop_machine(conv.id, pid)
    end
  end

  defp stop_machine(conv_id, pid) do
    GenServer.stop(pid)
    wait_unregistered(conv_id, 50)
  end

  defp wait_unregistered(_conv_id, 0), do: :ok

  defp wait_unregistered(conv_id, tries) do
    case Registry.lookup(SuperPi.Registry, {:conversation_machine, conv_id}) do
      [] ->
        :ok

      _ ->
        Process.sleep(5)
        wait_unregistered(conv_id, tries - 1)
    end
  end

  defp run_session(conv, pid, flags, positional, workspace_dirs, app_dir, opts) do
    prompt_text = flags.print || flags.prompt || Enum.join(positional, " ")

    result =
      cond do
        flags.input_format == "stream-json" ->
          run_stream_json_turns(conv.id, pid, opts, app_dir)

        Keyword.get(opts, :interactive_tui, false) and (prompt_text == "" or flags.prompt_interactive != nil) ->
          launch_interactive_tui(conv.id, flags, workspace_dirs, opts)

        prompt_text != "" or flags.prompt_interactive != nil ->
          effective_prompt = if prompt_text != "", do: prompt_text, else: flags.prompt_interactive

          case Machine.submit(pid, effective_prompt) do
            {:ok, :handled_by_extension} ->
              TranscriptLogger.sync_transcript!(conv.id, app_data_dir: app_dir)
              {0, format_output(%{"status" => "handled"}, flags.output_format)}

            {:ok, assistant_msg} ->
              TranscriptLogger.sync_transcript!(conv.id, app_data_dir: app_dir)
              {0, format_output(assistant_msg, flags.output_format)}

            {:error, reason} ->
              {1, format_output(%{"error" => format_reason(reason)}, flags.output_format)}
          end

        true ->
          chat_loop(conv.id, pid, flags, app_dir, opts)
      end

    result
  end

  # --- Interactive chat (line REPL) ---

  defp chat_loop(conv_id, pid, flags, app_dir, opts) do
    read = Keyword.get(opts, :read_line, &IO.gets/1)
    write = Keyword.get(opts, :write, &IO.write/1)
    Phoenix.PubSub.subscribe(SuperPi.PubSub, "conversation:#{conv_id}")
    # The terminal can answer `ask_question` calls from the model.
    SuperPi.UI.Broker.register_responder(conv_id)
    write.("Super-Pi conversation #{conv_id}. /exit to quit.\n")
    code = chat_turns(conv_id, pid, flags, app_dir, read, write)
    Phoenix.PubSub.unsubscribe(SuperPi.PubSub, "conversation:#{conv_id}")
    {code, ""}
  end

  defp chat_turns(conv_id, pid, flags, app_dir, read, write) do
    case read.("> ") do
      line when line in [:eof, nil] ->
        0

      {:error, _} ->
        1

      line ->
        case String.trim(line) do
          "" ->
            chat_turns(conv_id, pid, flags, app_dir, read, write)

          cmd when cmd in ["/exit", "/quit"] ->
            0

          text ->
            chat_turn(conv_id, pid, text, flags, app_dir, read, write)
            chat_turns(conv_id, pid, flags, app_dir, read, write)
        end
    end
  end

  # Runs one turn and prints text deltas as they arrive. Falls back to the final
  # message when the provider streamed nothing.
  defp chat_turn(conv_id, pid, text, flags, app_dir, read, write) do
    task = Task.async(fn -> Machine.submit(pid, text, timeout: :infinity) end)
    {result, streamed?} = await_turn(task, conv_id, read, write, false)

    case result do
      {:ok, :handled_by_extension} ->
        write.("[handled]\n")

      {:ok, msg} ->
        unless streamed?, do: write.(format_output(msg, "text"))
        write.("\n")

      {:error, reason} ->
        write.("\nerror: #{format_reason(reason)}\n")
    end

    TranscriptLogger.sync_transcript!(conv_id, app_data_dir: app_dir)
    flags
  end

  defp await_turn(%Task{ref: ref} = task, conv_id, read, write, streamed?) do
    receive do
      {:conversation_event, _id, %{"type" => "text_delta", "delta" => delta}} when is_binary(delta) ->
        write.(delta)
        await_turn(task, conv_id, read, write, true)

      {:conversation_event, _id, %{"type" => "ui_request", "kind" => "questionnaire"} = request} ->
        answer_questionnaire(conv_id, request, read, write)
        await_turn(task, conv_id, read, write, streamed?)

      {:conversation_event, _id, _other} ->
        await_turn(task, conv_id, read, write, streamed?)

      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        {result, streamed?}

      {:DOWN, ^ref, :process, _pid, reason} ->
        {{:error, reason}, streamed?}
    end
  end

  # Asks each question on the terminal. Type an option number (several, comma separated, for a
  # multi-select question) or free text. End of input cancels the question.
  defp answer_questionnaire(conv_id, %{"request_id" => request_id, "questions" => questions}, read, write) do
    answers =
      Enum.reduce_while(questions, [], fn q, acc ->
        case ask_one(q, read, write) do
          {:ok, selected} -> {:cont, [%{"question" => q["question"], "selected" => selected} | acc]}
          :eof -> {:halt, :eof}
        end
      end)

    case answers do
      :eof -> SuperPi.UI.Broker.cancel_pending(conv_id)
      list -> SuperPi.UI.Broker.respond(request_id, Enum.reverse(list))
    end
  end

  defp ask_one(q, read, write) do
    options = List.wrap(q["options"])
    multi? = q["is_multi_select"] == true

    write.("\n? #{q["question"]}\n")
    options |> Enum.with_index(1) |> Enum.each(fn {opt, i} -> write.("  #{i}) #{opt}\n") end)
    if multi?, do: write.("  (several numbers, separated by commas)\n")

    case read.("answer> ") do
      line when line in [:eof, nil] ->
        :eof

      {:error, _} ->
        :eof

      line ->
        case parse_choice(String.trim(line), options, multi?) do
          nil -> ask_one(q, read, write)
          selected -> {:ok, selected}
        end
    end
  end

  defp parse_choice("", _options, _multi?), do: nil

  defp parse_choice(text, options, multi?) do
    picks =
      text
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(fn token ->
        case Integer.parse(token) do
          {n, ""} when n >= 1 and n <= length(options) -> Enum.at(options, n - 1)
          _ -> token
        end
      end)

    if multi?, do: picks, else: if(length(options) > 0 and match?({_, ""}, Integer.parse(text)), do: hd(picks), else: text)
  end

  defp read_stdin_prompt(opts) do
    case Keyword.fetch(opts, :stdin_lines) do
      {:ok, lines} -> lines |> Enum.join("\n") |> String.trim()
      :error -> :stdio |> IO.read(:eof) |> to_string() |> String.trim()
    end
  end

  @read_only_agent_tools ["read", "grep", "find", "ls", "tool_search"]

  defp tools_for_agent("research") do
    Enum.filter(Tools.active_llm_tools(), &(&1["name"] in @read_only_agent_tools))
  end

  defp tools_for_agent(_agent), do: Tools.active_llm_tools()

  def launch_interactive_tui(conv_id, flags, workspace_dirs, opts \\ []) do
    {:ok, rpc_pid} = SuperPi.RPC.Server.start_link(port: 0)
    port = SuperPi.RPC.Server.port(rpc_pid)
    tui_bin = Keyword.get(opts, :tui_binary) || System.find_executable("super-pi-tui")

    res =
      if is_binary(tui_bin) and File.exists?(tui_bin) do
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
    servers = TranscriptLogger.mcp_list(opts)
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

    TranscriptLogger.mcp_add(name, spec, opts)
    {0, "Added MCP server #{name}"}
  end

  defp run_mcp_subcommand(["remove", name | _], opts) do
    case TranscriptLogger.mcp_remove(name, opts) do
      :ok -> {0, "Removed MCP server #{name}"}
      {:error, :not_found} -> {1, "MCP server not found: #{name}"}
    end
  end

  defp run_mcp_subcommand(["enable", name | _], opts) do
    case TranscriptLogger.mcp_set_enabled(name, true, opts) do
      :ok -> {0, "Enabled MCP server #{name}"}
      {:error, :not_found} -> {1, "MCP server not found: #{name}"}
    end
  end

  defp run_mcp_subcommand(["disable", name | _], opts) do
    case TranscriptLogger.mcp_set_enabled(name, false, opts) do
      :ok -> {0, "Disabled MCP server #{name}"}
      {:error, :not_found} -> {1, "MCP server not found: #{name}"}
    end
  end

  defp run_mcp_subcommand(_, _opts) do
    {0, "Usage: super-pi mcp <add|remove|list|enable|disable>"}
  end

  defp run_plugin_subcommand(["list" | _], flags, opts) do
    plugins = TranscriptLogger.plugin_list(opts)

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
    case TranscriptLogger.plugin_set_enabled(name, true, opts) do
      :ok -> {0, "Enabled plugin #{name}"}
      {:error, :not_found} -> {1, "Plugin not found: #{name}"}
    end
  end

  defp run_plugin_subcommand(["disable", name | _], _flags, opts) do
    case TranscriptLogger.plugin_set_enabled(name, false, opts) do
      :ok -> {0, "Disabled plugin #{name}"}
      {:error, :not_found} -> {1, "Plugin not found: #{name}"}
    end
  end

  defp run_plugin_subcommand(["validate", path | _], _flags, _opts) do
    case TranscriptLogger.plugin_validate(path) do
      {:ok, info} -> {0, Jason.encode!(info)}
      {:error, info} -> {1, Jason.encode!(info)}
    end
  end

  defp run_plugin_subcommand(_, _flags, _opts) do
    {0, "Usage: super-pi plugin <list|enable|disable|validate>"}
  end

  defp run_remote_control_subcommand(["status" | _]) do
    case Process.whereis(SuperPi.RPC.Server) do
      nil -> {1, Jason.encode!(%{"daemon" => "super_pi_rpc", "status" => "stopped"})}
      pid -> {0, Jason.encode!(%{"daemon" => "super_pi_rpc", "status" => "ready", "port" => SuperPi.RPC.Server.port(pid)})}
    end
  end

  defp run_remote_control_subcommand(["start" | _]) do
    {:ok, pid} = SuperPi.RPC.Server.start_link(port: 0)
    port = SuperPi.RPC.Server.port(pid)
    {0, Jason.encode!(%{"daemon" => "super_pi_rpc", "status" => "started", "port" => port})}
  end

  defp run_remote_control_subcommand(_) do
    {0, "Usage: super-pi remote-control <start|status|stop>"}
  end

  # --- Helpers ---

  # With injected `:stdin_lines` the results are returned as one string. With real
  # stdin each turn result is printed as soon as it is ready, so a driver process
  # can read one JSON line per turn.
  defp run_stream_json_turns(conv_id, pid, opts, app_dir) do
    {lines, live?} =
      case Keyword.fetch(opts, :stdin_lines) do
        {:ok, lines} -> {lines, false}
        :error -> {IO.stream(:stdio, :line), true}
      end

    results =
      lines
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.map(fn line ->
        {code, json} = stream_json_turn(conv_id, pid, line)
        if live?, do: IO.puts(json)
        {code, json}
      end)

    TranscriptLogger.sync_transcript!(conv_id, app_data_dir: app_dir)
    code = if Enum.any?(results, fn {c, _} -> c != 0 end), do: 1, else: 0
    {code, if(live?, do: "", else: results |> Enum.map(&elem(&1, 1)) |> Enum.join("\n"))}
  end

  defp stream_json_turn(conv_id, pid, line) do
    prompt =
      case Jason.decode(line) do
        {:ok, %{"prompt" => p}} -> p
        {:ok, %{"text" => t}} -> t
        _ -> line
      end

    if is_binary(prompt) do
      case Machine.submit(pid, prompt) do
        {:ok, msg} ->
          {0, Jason.encode!(%{"type" => "turn_result", "conversation_id" => conv_id, "message" => msg_json(msg)})}

        {:error, reason} ->
          {1, Jason.encode!(%{"type" => "turn_error", "conversation_id" => conv_id, "error" => format_reason(reason)})}
      end
    else
      {1, Jason.encode!(%{"type" => "turn_error", "conversation_id" => conv_id, "error" => "prompt must be a string"})}
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp msg_json(msg) when is_atom(msg), do: Atom.to_string(msg)
  defp msg_json(msg), do: msg

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
      harness: Keyword.get(parsed, :harness),
      help: Keyword.get(parsed, :help, false),
      input_format: Keyword.get(parsed, :input_format, "text"),
      json: Keyword.get(parsed, :json, false),
      json_schema: Keyword.get(parsed, :json_schema),
      mode: Keyword.get(parsed, :mode, "auto"),
      model: Keyword.get(parsed, :model),
      output_format: Keyword.get(parsed, :output_format, "text"),
      print: Keyword.get(parsed, :print),
      prompt: Keyword.get(parsed, :prompt),
      prompt_interactive: Keyword.get(parsed, :prompt_interactive),
      sandbox: Keyword.get(parsed, :sandbox, false),
      settings: Keyword.get(parsed, :settings)
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
      [{pid, _}] ->
        {:ok, pid, false}

      [] ->
        with {:ok, pid} <- Machine.start_link(opts), do: {:ok, pid, true}
    end
  end

  defp maybe_put(kw, _k, nil), do: kw
  defp maybe_put(kw, k, v), do: Keyword.put(kw, k, v)

  defp maybe_override(map, _key, nil), do: map
  defp maybe_override(map, key, val), do: Map.put(map, key, val)

  def help_text do
    """
    Usage: super-pi [command] [options] [prompt]

    Options:
      -H, --harness                   Agent harness (workspace, default, fast, auto, interactive, planner)
      -p, --print, --prompt           Run a single prompt non-interactively and print the response
      -i, --prompt-interactive        Run an initial prompt interactively
      -c, --continue                  Continue the most recent conversation
      --conversation <id>             Resume a previous conversation by numeric ID
      --model <model>                 Active LLM model
      --mode <mode>                   Execution mode (auto, accept-edits, plan)
      --effort <level>                Reasoning effort (low, medium, high, xhigh, max)
      --agent <profile>               Agent profile (self, research, image-generator)
      --add-dir <path>                Add a directory to the workspace (repeatable)
      --input-format <format>         Input format (text, stream-json)
      --output-format <format>        Output format (text, json, stream-json)
      --dangerously-skip-permissions  Auto-approve tool permissions without confirmation
      --disable-slash-commands        Disable slash command preprocessing
      --sandbox                       Run in an isolated execution sandbox
      --settings <json|file>          Session settings overrides
      --json-schema <json|file>       Enforce structured JSON output schema
      -h, --help                      Show help

    Commands:
      harnesses                       List available agent harnesses
      models                          List available LLM models
      agents                          List available agent profiles
      mcp <list|add|remove|enable|disable> Manage MCP server configurations
      plugins <list|enable|disable|validate> Manage workspace plugins
      remote-control <start|status|stop> Control RPC daemon
      run [prompt]                    Run one prompt (reads stdin when no prompt is given)
      chat                            Interactive chat (default when stdin is a terminal)
      gateway [port]                  Start upstream inference HTTP gateway
      session <list|show <id>>        Inspect durable conversation sessions
    """
  end
end
