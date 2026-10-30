defmodule SuperPi.TUI.Owl do
  @moduledoc """
  Day-1 Interactive Terminal UI built on `Owl` (`Decision 10`, `Step 10`).

  Provides formatted ANSI status bars, streaming assistant response rendering, tool execution
  boxes, and slash-command handling (`/compact`, `/fork`, `/context`, `/quit`) backed directly
  by `SuperPi.Conversation.Machine`.
  """

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Context, Doc, Storage}

  @doc """
  Renders a formatted ANSI status banner for `conversation_id` using `Owl.Data` tags.
  """
  def render_status_bar(conversation_id) do
    live = Doc.snapshot("conversation", conversation_id, "pi.live") || %{"status" => "idle"}
    agent = Doc.snapshot("conversation", conversation_id, "pi.agent") || %{}
    usage = Doc.snapshot("conversation", conversation_id, "pi.usage") || %{}

    default_model =
      if Application.get_env(:super_pi, :default_model) || SuperPi.AI.GeminiClient.configured?() do
        SuperPi.Harness.Defaults.default_model()
      else
        "claude-sonnet-4-5"
      end

    model = Map.get(agent, "model", default_model)
    status = Map.get(live, "status", "idle")
    in_tok = Map.get(usage, "inputTokens", 0)
    out_tok = Map.get(usage, "outputTokens", 0)

    Owl.Data.tag(
      "[Super-Pi-BEAM | conv:##{conversation_id} | model:#{model} | state:#{status} | tokens:#{in_tok}in/#{out_tok}out]",
      :cyan
    )
    |> Owl.Data.to_chardata()
    |> IO.iodata_to_binary()
  end

  @doc """
  Renders an assistant message and any embedded tool call blocks as ANSI-formatted text.
  """
  def render_assistant_message(:handled_by_extension), do: ""
  def render_assistant_message(nil), do: ""

  def render_assistant_message(%{"content" => blocks}) when is_list(blocks) do
    blocks
    |> Enum.map(fn
      %{"type" => "thinking", "thinking" => t} ->
        Owl.Data.tag("💭 #{t}", :light_black) |> Owl.Data.to_chardata() |> IO.iodata_to_binary()

      %{"type" => "text", "text" => t} ->
        Owl.Data.tag(t, :green) |> Owl.Data.to_chardata() |> IO.iodata_to_binary()

      %{"type" => "tool_call", "name" => name, "arguments" => args} ->
        Owl.Data.tag("🔧 #{name}(#{Jason.encode!(args)})", :yellow)
        |> Owl.Data.to_chardata()
        |> IO.iodata_to_binary()

      other ->
        inspect(other)
    end)
    |> Enum.join("\n")
  end

  def render_assistant_message(%{"content" => text}) when is_binary(text) do
    Owl.Data.tag(text, :green) |> Owl.Data.to_chardata() |> IO.iodata_to_binary()
  end

  def render_assistant_message(text) when is_binary(text), do: text
  def render_assistant_message(other), do: inspect(other)

  @doc """
  Executes a single TUI command or prompt line against `conversation_id` and returns the formatted string output.
  """
  def handle_line(conversation_id, pid, line) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      trimmed in ["/quit", "/exit", ":q"] ->
        "Session ended."

      trimmed == "/fork" ->
        {visible, _graph} = Context.visible_entries_with_graph(conversation_id)

        case List.last(visible) do
          nil ->
            "Cannot fork conversation ##{conversation_id}: no entries to fork from."

          last_entry ->
            child = Storage.fork_conversation!(conversation_id, last_entry.id)
            "Forked conversation ##{conversation_id} to ##{child.id}"
        end

      trimmed == "/status" ->
        render_status_bar(conversation_id)

      trimmed == "/compact" ->
        case Machine.compact(pid) do
          {:ok, :cancelled} ->
            "Compaction cancelled."

          {:ok, :noop} ->
            "Compaction no-op: context size does not exceed threshold."

          {:ok, %{head_entry_id: head_id, summary: summary}} ->
            "Compacted conversation ##{conversation_id} (head_entry_id=#{head_id}): #{summary}"

          {:ok, info} when is_map(info) ->
            head_id = Map.get(info, :head_entry_id) || Map.get(info, "head_entry_id")
            summary = Map.get(info, :summary) || Map.get(info, "summary")
            "Compacted conversation ##{conversation_id} (head_entry_id=#{head_id}): #{summary}"

          {:ok, other} ->
            "Compaction finished: #{inspect(other)}"

          {:error, reason} ->
            "Compaction failed: #{inspect(reason)}"
        end

      trimmed == "/context" ->
        derived = Context.derive(conversation_id)

        "Derived context: #{length(derived.messages)} messages, #{length(derived.tools)} active tools."

      true ->
        case Machine.submit(pid, trimmed, mode: :queue) do
          {:ok, msg} ->
            render_assistant_message(msg)

          {:error, reason} ->
            "Error: #{inspect(reason)}"
        end
    end
  end

  @doc """
  Starts an interactive session for `conversation_id`, supporting pluggable harnesses and extensions.
  """
  def start_session(opts \\ []) do
    harness_key = Keyword.get(opts, :harness, "super-pi-code")
    harness = SuperPi.Harness.resolve(harness_key)

    agent_opts = Keyword.get(opts, :agent, %{})
    defaults = harness.agent_defaults()
    agent_cfg = Map.merge(defaults, agent_opts)

    conv = Storage.ensure_root_conversation!(agent_cfg)
    extensions = Keyword.get(opts, :extensions, harness.extensions([]))

    {:ok, pid} = Machine.start_link(conversation_id: conv.id, extensions: extensions)
    {conv.id, pid}
  end
end
