defmodule SuperPi.Artifacts.Ecto do
  @moduledoc "Artifact store in the repo (`artifacts` table): PostgreSQL, or SQLite on a single node."

  @behaviour SuperPi.Artifacts.Store

  import Ecto.Query

  alias SuperPi.Repo

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    schema "artifacts" do
      field(:conversation_id, :integer)
      field(:name, :string)
      field(:content_type, :string)
      field(:size, :integer)
      field(:data, :binary)

      timestamps(type: :utc_datetime_usec)
    end
  end

  @impl true
  def put(conversation_id, name, data, content_type) do
    Repo.transaction(fn ->
      existing? =
        Repo.one(
          from(a in Row,
            where: a.conversation_id == ^conversation_id and a.name == ^name,
            select: a.id
          )
        ) != nil

      count =
        Repo.one(
          from(a in Row, where: a.conversation_id == ^conversation_id, select: count(a.id))
        )

      if not existing? and count >= SuperPi.Artifacts.max_count() do
        Repo.active_repo().rollback({:too_many, SuperPi.Artifacts.max_count()})
      end

      now = DateTime.utc_now()

      Repo.insert_all(
        Row,
        [
          %{
            conversation_id: conversation_id,
            name: name,
            content_type: content_type,
            size: byte_size(data),
            data: data,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: {:replace, [:content_type, :size, :data, :updated_at]},
        conflict_target: [:conversation_id, :name]
      )

      %{name: name, size: byte_size(data)}
    end)
  end

  @impl true
  def get(conversation_id, name) do
    case Repo.one(
           from(a in Row,
             where: a.conversation_id == ^conversation_id and a.name == ^name,
             select: {a.data, a.content_type, a.size}
           )
         ) do
      nil -> {:error, :not_found}
      {data, type, size} -> {:ok, %{data: data, content_type: type, size: size}}
    end
  end

  @impl true
  def list(conversation_id) do
    Repo.all(
      from(a in Row,
        where: a.conversation_id == ^conversation_id,
        order_by: [asc: a.name],
        select: %{
          name: a.name,
          size: a.size,
          content_type: a.content_type,
          updated_at: a.updated_at
        }
      )
    )
  end

  @impl true
  def delete(conversation_id, name) do
    case Repo.delete_all(
           from(a in Row, where: a.conversation_id == ^conversation_id and a.name == ^name)
         ) do
      {0, _} -> {:error, :not_found}
      {_, _} -> :ok
    end
  end
end
