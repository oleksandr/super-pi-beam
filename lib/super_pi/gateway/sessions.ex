defmodule SuperPi.Gateway.Sessions do
  @moduledoc """
  Stored mapping from a client session id to a conversation, per principal.

  The mapping is a table, so it survives a restart and is shared by every node. The unique index
  on `(principal, session_id)` decides a race between two requests (on one node or several): one
  creates the mapping, the other finds it and discards the conversation it had made.

  Rows idle longer than `config :super_pi, gateway_session_ttl_days` (default 90) are deleted,
  and the table keeps at most `gateway_session_limit` rows (default 100_000), oldest first. A
  deleted session id starts a new conversation.
  """

  import Ecto.Query

  alias SuperPi.Durable.Schemas.Conversation
  alias SuperPi.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    schema "gateway_sessions" do
      field :principal, :string
      field :session_id, :string
      field :conversation_id, :integer
      field :last_used_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end
  end

  @doc "The conversation id for a session, or `nil`."
  def lookup(principal, session_id) do
    Repo.one(from s in Row, where: s.principal == ^principal and s.session_id == ^session_id, select: s.conversation_id)
  end

  @doc """
  Returns `{conversation_id, new?}`. `create_fun` makes a conversation when the session is new.
  """
  def fetch_or_create(principal, session_id, create_fun) when is_function(create_fun, 0) do
    case lookup(principal, session_id) do
      nil -> create(principal, session_id, create_fun)
      conv_id ->
        touch(principal, session_id)
        {conv_id, false}
    end
  end

  defp create(principal, session_id, create_fun) do
    conv = create_fun.()
    now = DateTime.utc_now()

    # `returning` tells us whether this call inserted the row. The affected-row count is not
    # reliable on SQLite when the connection is shared.
    {_count, inserted} =
      Repo.insert_all(
        Row,
        [%{principal: principal, session_id: session_id, conversation_id: conv.id, last_used_at: now, inserted_at: now, updated_at: now}],
        on_conflict: :nothing,
        conflict_target: [:principal, :session_id],
        returning: [:id]
      )

    if inserted != [] do
      prune()
      {conv.id, true}
    else
      # Another request created the session first. Use its conversation and drop ours.
      Repo.delete_all(from c in Conversation, where: c.id == ^conv.id)
      {lookup(principal, session_id), false}
    end
  end

  # Last-use time is kept to the minute, so a busy session does not write on every request.
  defp touch(principal, session_id) do
    now = DateTime.utc_now()
    stale = DateTime.add(now, -60, :second)

    Repo.update_all(
      from(s in Row, where: s.principal == ^principal and s.session_id == ^session_id and s.last_used_at < ^stale),
      set: [last_used_at: now]
    )

    :ok
  end

  @doc "Deletes expired rows and rows beyond the limit. Returns the number deleted."
  def prune do
    ttl_days = Application.get_env(:super_pi, :gateway_session_ttl_days, 90)
    limit = Application.get_env(:super_pi, :gateway_session_limit, 100_000)
    cutoff = DateTime.add(DateTime.utc_now(), -ttl_days * 86_400, :second)

    {expired, _} = Repo.delete_all(from s in Row, where: s.last_used_at < ^cutoff)

    over =
      case Repo.one(from s in Row, select: count(s.id)) do
        n when n > limit -> n - limit
        _ -> 0
      end

    excess =
      if over > 0 do
        ids = Repo.all(from s in Row, order_by: [asc: s.last_used_at, asc: s.id], limit: ^over, select: s.id)
        {n, _} = Repo.delete_all(from s in Row, where: s.id in ^ids)
        n
      else
        0
      end

    expired + excess
  end

  @doc "Number of stored sessions."
  def count, do: Repo.one(from s in Row, select: count(s.id))
end
