defmodule SuperPi.MCP.Sessions do
  @moduledoc """
  Sessions of the Streamable HTTP server (`SuperPi.MCP.HTTPPlug`): the id a client carries in
  `Mcp-Session-Id`, and the connection state that `SuperPi.MCP.Server.handle_mcp_line/2` threads.

  The table lives on the node that answered `initialize`. A request that reaches another node
  finds no session and gets `404`, which a conforming client answers by starting a new session,
  so a cluster needs no shared session store (sticky routing only saves the round trip).

  A session expires after `mcp_session_ttl_ms` without a request (default one hour). At most
  `mcp_max_sessions` exist at once (default 1000), so a client that only calls `initialize`
  cannot fill memory.
  """

  @table :super_pi_mcp_sessions
  @default_ttl_ms 3_600_000
  @default_max 1_000

  @doc false
  # Created at boot by `SuperPi.MCP.Manager.create_tables/0`, which runs in a process that outlives
  # every request. A table owned by a request process would vanish with it.
  def create_table do
    if :ets.whereis(@table) == :undefined do
      try do
        :ets.new(@table, [:named_table, :public, :set])
      rescue
        ArgumentError -> :ok
      end
    end

    :ok
  end

  @doc "Starts a session with `state`. Returns `{:ok, id}`, or `{:error, :full}` at the limit."
  @spec create(map()) :: {:ok, String.t()} | {:error, :full}
  def create(state) when is_map(state) do
    create_table()
    prune()

    if :ets.info(@table, :size) >= Application.get_env(:super_pi, :mcp_max_sessions, @default_max) do
      {:error, :full}
    else
      id = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      :ets.insert(@table, {id, state, now()})
      {:ok, id}
    end
  end

  @doc "The state of a live session. A request counts as use, so an active session does not expire."
  @spec fetch(term()) :: {:ok, map()} | :error
  def fetch(id) when is_binary(id) do
    create_table()

    case :ets.lookup(@table, id) do
      [{^id, state, last_used}] ->
        if now() - last_used > ttl() do
          :ets.delete(@table, id)
          :error
        else
          :ets.update_element(@table, id, {3, now()})
          {:ok, state}
        end

      [] ->
        :error
    end
  end

  def fetch(_), do: :error

  @doc "Stores the next state of a live session. A session that ended meanwhile stays ended."
  @spec put(String.t(), map()) :: :ok
  def put(id, state) when is_binary(id) and is_map(state) do
    create_table()
    :ets.update_element(@table, id, [{2, state}, {3, now()}])
    :ok
  end

  @doc "Ends a session. Returns `:ok`, or `:error` when there was none."
  @spec delete(term()) :: :ok | :error
  def delete(id) when is_binary(id) do
    create_table()
    if :ets.take(@table, id) == [], do: :error, else: :ok
  end

  def delete(_), do: :error

  @doc "Number of live sessions."
  def count do
    create_table()
    prune()
    :ets.info(@table, :size)
  end

  @doc "Drops every session. For tests."
  def clear do
    create_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  defp prune do
    cutoff = now() - ttl()
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", cutoff}], [true]}])
  end

  defp ttl, do: Application.get_env(:super_pi, :mcp_session_ttl_ms, @default_ttl_ms)
  defp now, do: System.monotonic_time(:millisecond)
end
