defmodule SuperPi.Repo.SQLite do
  use Ecto.Repo,
    otp_app: :super_pi,
    adapter: Ecto.Adapters.SQLite3
end

defmodule SuperPi.Repo.Postgres do
  use Ecto.Repo,
    otp_app: :super_pi,
    adapter: Ecto.Adapters.Postgres
end

defmodule SuperPi.Repo do
  @moduledoc """
  Unified repository facade that dispatches to `SuperPi.Repo.SQLite` (default single-node WAL mode)
  or `SuperPi.Repo.Postgres` (PostgreSQL, single node) based on `:storage_backend` configuration.
  """

  @spec active_repo() :: module()
  def active_repo do
    case Application.get_env(:super_pi, :storage_backend, :sqlite) do
      :postgres -> SuperPi.Repo.Postgres
      _ -> SuperPi.Repo.SQLite
    end
  end

  def transaction(fun_or_multi, opts \\ []) do
    active_repo().transaction(fun_or_multi, opts)
  end

  def all(queryable, opts \\ []), do: active_repo().all(queryable, opts)
  def one(queryable, opts \\ []), do: active_repo().one(queryable, opts)
  def one!(queryable, opts \\ []), do: active_repo().one!(queryable, opts)
  def get(queryable, id, opts \\ []), do: active_repo().get(queryable, id, opts)
  def get!(queryable, id, opts \\ []), do: active_repo().get!(queryable, id, opts)
  def get_by(queryable, clauses, opts \\ []), do: active_repo().get_by(queryable, clauses, opts)
  def insert(struct_or_changeset, opts \\ []), do: active_repo().insert(struct_or_changeset, opts)
  def insert!(struct_or_changeset, opts \\ []), do: active_repo().insert!(struct_or_changeset, opts)
  def update(changeset, opts \\ []), do: active_repo().update(changeset, opts)
  def update!(changeset, opts \\ []), do: active_repo().update!(changeset, opts)
  def delete(struct_or_changeset, opts \\ []), do: active_repo().delete(struct_or_changeset, opts)
  def delete_all(queryable, opts \\ []), do: active_repo().delete_all(queryable, opts)
  def update_all(queryable, updates, opts \\ []), do: active_repo().update_all(queryable, updates, opts)
  def query!(sql, params \\ [], opts \\ []), do: active_repo().query!(sql, params, opts)
end
