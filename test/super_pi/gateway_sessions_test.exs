defmodule SuperPi.GatewaySessionsTest do
  @moduledoc "The session-id to conversation map is stored (Task 47)."
  use SuperPi.DataCase, async: false

  import Ecto.Query

  alias SuperPi.Durable.Schemas.Conversation
  alias SuperPi.Durable.Storage
  alias SuperPi.Gateway.Sessions

  defp conversations, do: Repo.one(from c in Conversation, select: count(c.id))
  defp make, do: fn -> Storage.create_conversation!() end

  test "a session id maps to the same conversation, per principal" do
    {a, true} = Sessions.fetch_or_create("alice", "s1", make())
    assert {^a, false} = Sessions.fetch_or_create("alice", "s1", make())

    {b, true} = Sessions.fetch_or_create("bob", "s1", make())
    refute a == b
  end

  test "the mapping is in the table, so it does not depend on any process or cache" do
    {conv, true} = Sessions.fetch_or_create("alice", "durable", make())
    # Drop everything node-local that the old implementation used.
    for table <- [:super_pi_gateway_sessions, :super_pi_doc_cache], :ets.whereis(table) != :undefined, do: :ets.delete_all_objects(table)

    assert Sessions.lookup("alice", "durable") == conv
    assert {^conv, false} = Sessions.fetch_or_create("alice", "durable", make())
  end

  test "a race for a new session leaves one mapping and one conversation" do
    before = conversations()

    results = 1..6 |> Task.async_stream(fn _ -> Sessions.fetch_or_create("alice", "race", make()) end, max_concurrency: 6, timeout: 10_000) |> Enum.map(fn {:ok, r} -> r end)

    assert results |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == 1
    assert Enum.count(results, &match?({_, true}, &1)) == 1
    assert conversations() - before == 1
    assert Sessions.count() == 1
  end

  test "idle sessions expire" do
    Application.put_env(:super_pi, :gateway_session_ttl_days, 1)
    on_exit(fn -> Application.delete_env(:super_pi, :gateway_session_ttl_days) end)

    {_, true} = Sessions.fetch_or_create("alice", "old", make())
    old = DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)
    Repo.update_all(from(s in Sessions.Row, where: s.session_id == "old"), set: [last_used_at: old])
    {_, true} = Sessions.fetch_or_create("alice", "new", make())

    assert Sessions.lookup("alice", "old") == nil
    assert Sessions.lookup("alice", "new")
  end

  test "deleting a conversation deletes its session" do
    {conv, true} = Sessions.fetch_or_create("alice", "gone", make())
    Repo.delete_all(from c in Conversation, where: c.id == ^conv)
    assert Sessions.lookup("alice", "gone") == nil
  end
end
