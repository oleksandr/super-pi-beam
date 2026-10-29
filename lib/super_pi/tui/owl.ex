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
      if SuperPi.AI.GeminiClient.configured?() do
        "gemini-3-flash-preview"
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

  @doc """
  Executes a single TUI command or prompt line against `conversation_id` and returns the formatted string output.
  """
  def handle_line(conversation_id, pid, line) when is_binary(line) do
    trimmed = String.trim(line)

    cond do
      trimmed == "/status" ->
        render_status_bar(conversation_id)

      trimmed == "/compact" ->
        {:ok, info} = Machine.compact(pid)
        "Compacted conversation ##{conversation_id} (head_entry_id=#{info.head_entry_id}): #{info.summary}"

      trimmed == "/context" ->
        derived = Context.derive(conversation_id)
        "Derived context: #{length(derived.messages)} messages, #{length(derived.tools)} active tools."

      true ->
        {:ok, msg} = Machine.submit(pid, trimmed, mode: :queue)
        render_assistant_message(msg)
    end
  end

  @doc """
  Starts an interactive session for `conversation_id`, supporting pluggable harnesses and extensions.
  """
  def start_session(opts \\ []) do
    harness_key = Keyword.get(opts, :harness, "default")
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
