defmodule SuperPi.Durable.Schemas.Document do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "documents" do
    field(:kind, :string)
    field(:key, :string, default: "")
    field(:scope_kind, :string)
    field(:scope_id, :integer, default: 0)
    field(:history_policy, :string, default: "latest")
    field(:fork_policy, :string, default: "current")
    field(:created_seq, :integer)
    field(:retired_seq, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(doc, attrs) do
    doc
    |> cast(attrs, [
      :kind,
      :key,
      :scope_kind,
      :scope_id,
      :history_policy,
      :fork_policy,
      :created_seq,
      :retired_seq
    ])
    |> validate_required([
      :kind,
      :scope_kind,
      :scope_id,
      :history_policy,
      :fork_policy,
      :created_seq
    ])
    |> unique_constraint([:scope_kind, :scope_id, :kind, :key],
      name: :documents_active_unique_index
    )
  end
end

defmodule SuperPi.Durable.Schemas.DocumentRevision do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "document_revisions" do
    field(:document_id, :integer)
    field(:seq, :integer)
    field(:version, :integer, default: 1)
    field(:is_checkpoint_base, :boolean, default: false)
    field(:value, :map)
    field(:ops, :map, default: %{"ops" => []})

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(rev, attrs) do
    rev
    |> cast(attrs, [:document_id, :seq, :version, :is_checkpoint_base, :value, :ops])
    |> validate_required([:document_id, :seq, :version, :is_checkpoint_base])
    |> unique_constraint([:document_id, :seq])
  end
end
