defmodule SuperPi.Env.Shared do
  @moduledoc """
  Execution environment for a workspace on shared storage (NFS, CephFS, a read-write-many volume).

  Reads, listing and commands are the same as `SuperPi.Env.Local`. Writes and edits also take a
  PostgreSQL advisory lock for the path, so two nodes cannot change the same file at once. The
  `SuperPi.Env.FileLock` that `Local` uses only serializes writers on one node.

  With SQLite (one node) there is no other node, so the local lock is enough and no advisory lock
  is taken.
  """

  @behaviour SuperPi.Env.Behaviour

  alias SuperPi.Env.Local
  alias SuperPi.Repo

  @impl true
  def id, do: "shared"

  @impl true
  defdelegate read_file(path, opts \\ []), to: Local

  @impl true
  def write_file(path, content, opts \\ []) do
    locked(path, fn -> Local.write_file(path, content, Keyword.put(opts, :env_id, "shared")) end)
  end

  @impl true
  def edit_file(path, old_text, new_text, opts \\ []) do
    locked(path, fn -> Local.edit_file(path, old_text, new_text, Keyword.put(opts, :env_id, "shared")) end)
  end

  @impl true
  defdelegate list_files(root_dir, opts \\ []), to: Local

  @impl true
  defdelegate scan_lines(root_dir, pattern, opts \\ []), to: Local

  @impl true
  defdelegate exec_command(cmd, args \\ [], opts \\ []), to: Local

  @doc "Key of the advisory lock for a path: a signed 64-bit integer from a hash of the path."
  def lock_key(path) do
    <<key::signed-64, _rest::binary>> = :crypto.hash(:md5, "super_pi_shared_file:" <> Path.expand(path))
    key
  end

  defp locked(path, fun) do
    if Repo.active_repo() == SuperPi.Repo.Postgres do
      result =
        Repo.transaction(
          fn ->
            # Held until the transaction ends, which is after the file operation.
            Repo.query!("SELECT pg_advisory_xact_lock($1)", [lock_key(path)])
            fun.()
          end,
          timeout: 120_000
        )

      case result do
        {:ok, value} -> value
        {:error, reason} -> {:error, reason}
      end
    else
      fun.()
    end
  end
end
