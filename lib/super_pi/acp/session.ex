defmodule SuperPi.ACP.Session do
  @moduledoc """
  One ACP session: its id, its conversation, the renderer state and the running prompt.

  The `sessionId` is an opaque string (`acp_...`), not the conversation id. Editors such as Zed store
  it and send it back on `session/load`, possibly after a restart, so the mapping lives in
  `SuperPi.Gateway.Sessions` (a table), per principal.
  """

  alias SuperPi.Conversation.Machine
  alias SuperPi.Durable.{Doc, Storage}
  alias SuperPi.Event.{History, Renderer}
  alias SuperPi.Gateway.Sessions
  alias SuperPi.Harness
  alias SuperPi.Plugins.Permissions

  @enforce_keys [:id, :conversation_id]
  defstruct [:id, :conversation_id, :renderer, :prompt, :last_end, cwd: nil]

  @type t :: %__MODULE__{}

  @modes [
    %{
      "id" => "plan",
      "name" => "Plan",
      "description" => "Read-only. Inspect and plan, change nothing."
    },
    %{
      "id" => "accept-edits",
      "name" => "Accept edits",
      "description" => "Edit files. Other tools ask first."
    },
    %{"id" => "auto", "name" => "Auto", "description" => "Run every tool without asking."}
  ]

  @doc "Creates a session and its conversation. `harness` is the harness module."
  @spec create(String.t(), String.t(), module(), keyword()) :: t()
  def create(principal, cwd, harness, opts \\ []) do
    session_id = "acp_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    agent =
      harness.agent_defaults(workspace_paths: [cwd])
      |> Permissions.apply_remote_mode(Keyword.get(opts, :mode))
      |> Map.put("harness", harness.id())

    {conv_id, true} =
      Sessions.fetch_or_create(principal, session_id, fn ->
        Storage.create_conversation!(agent: agent, owner: principal)
      end)

    build(session_id, conv_id, cwd)
  end

  @doc "Finds an existing session. Returns `{:ok, session}` or `:error`."
  @spec load(String.t(), String.t(), String.t()) :: {:ok, t()} | :error
  def load(principal, session_id, cwd) do
    case Sessions.lookup(principal, session_id) do
      nil -> :error
      conv_id -> {:ok, build(session_id, conv_id, cwd)}
    end
  end

  defp build(session_id, conv_id, cwd) do
    %__MODULE__{
      id: session_id,
      conversation_id: conv_id,
      cwd: cwd,
      renderer: Renderer.ACP.init(session_id: session_id)
    }
  end

  @doc """
  Forks the conversation at its latest visible entry into a new session (`_superpi/session/fork`).
  `session/load` resumes, so a fork is a separate custom method.
  """
  @spec fork(String.t(), t()) :: {:ok, t()} | {:error, term()}
  def fork(principal, %__MODULE__{} = session) do
    {visible, _graph} =
      SuperPi.Durable.Context.visible_entries_with_graph(session.conversation_id)

    case List.last(visible) do
      nil ->
        {:error, :empty_conversation}

      %{id: entry_id} ->
        fork_conv =
          Storage.fork_conversation!(session.conversation_id, entry_id, owner: principal)

        session_id = "acp_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
        {conv_id, true} = Sessions.fetch_or_create(principal, session_id, fn -> fork_conv end)
        {:ok, build(session_id, conv_id, session.cwd)}
    end
  end

  @doc "The modes a client may pick: up to the remote ceiling and the harness ceiling."
  @spec modes(integer()) :: %{String.t() => term()}
  def modes(conversation_id) do
    agent = Doc.snapshot("conversation", conversation_id, "pi.agent") || %{}
    ceiling = Permissions.rank_of(Permissions.remote_mode("auto"))
    max_rank = min(ceiling, Permissions.rank_of(Map.get(agent, "maxExecutionMode", "auto")))
    available = Enum.filter(@modes, &(Permissions.rank_of(&1["id"]) <= max_rank))

    %{"currentModeId" => Map.get(agent, "executionMode"), "availableModes" => available}
  end

  @doc "Sets the mode. The mode must be one of `modes/1`."
  @spec set_mode(integer(), String.t()) :: :ok | {:error, String.t()}
  def set_mode(conversation_id, mode_id) do
    if Enum.any?(modes(conversation_id)["availableModes"], &(&1["id"] == mode_id)) do
      Storage.configure_agent!(conversation_id, %{"executionMode" => mode_id})
      :ok
    else
      {:error, "Mode #{inspect(mode_id)} is not available for this session"}
    end
  end

  @doc "The history of the session as `session/update` payloads, for `session/load`."
  @spec replay(t()) :: [map()]
  def replay(%__MODULE__{conversation_id: conv_id}) do
    conv_id
    |> History.messages()
    |> Enum.flat_map(fn
      %{"role" => "user", "text" => text} when text != "" ->
        [chunk("user_message_chunk", text)]

      %{"role" => "assistant"} = m ->
        text = if m["text"] in [nil, ""], do: [], else: [chunk("agent_message_chunk", m["text"])]

        calls =
          for c <- m["tool_calls"] || [],
              do: %{
                "sessionUpdate" => "tool_call",
                "toolCallId" => c["id"],
                "title" => to_string(c["name"]),
                "kind" => Renderer.ACP.kind(c["name"]),
                "status" => "completed",
                "rawInput" => c["arguments"] || %{}
              }

        text ++ calls

      %{"role" => "tool"} = m ->
        [
          %{
            "sessionUpdate" => "tool_call_update",
            "toolCallId" => m["tool_call_id"],
            "status" => if(m["is_error"], do: "failed", else: "completed"),
            "content" => [
              %{"type" => "content", "content" => %{"type" => "text", "text" => m["text"]}}
            ]
          }
        ]

      _ ->
        []
    end)
  end

  defp chunk(kind, text),
    do: %{"sessionUpdate" => kind, "content" => %{"type" => "text", "text" => text}}

  @doc "Cancels the turn. The order is load-bearing: pending prompts first, then the machine."
  @spec cancel(t()) :: :ok
  def cancel(%__MODULE__{conversation_id: conv_id}) do
    # A turn that waits in `UI.Broker.ask` cannot handle the cancel message until the wait ends.
    SuperPi.UI.Broker.cancel_pending(conv_id)

    case SuperPi.Conversation.Locator.whereis(conv_id) do
      pid when is_pid(pid) ->
        try do
          Machine.cancel(pid)
        catch
          :exit, _ -> :ok
        end

      nil ->
        :ok
    end

    :ok
  end

  @doc "The harness named in `_meta.harness` of a request, or the default."
  @spec pick_harness(map() | nil) :: {:ok, module()} | {:error, String.t()}
  def pick_harness(meta) do
    case is_map(meta) && meta["harness"] do
      name when is_binary(name) ->
        case Harness.fetch(name) do
          {:ok, mod} -> {:ok, mod}
          {:error, _} -> {:error, "Unknown harness: #{name}"}
        end

      _ ->
        {:ok, Harness.default()}
    end
  end
end
