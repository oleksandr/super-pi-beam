defmodule SuperPi.Durable.Schemas.Entry do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "entries" do
    field(:conversation_id, :integer)
    field(:seq, :integer)
    field(:kind, :string)
    field(:head_entry_id, :integer)
    field(:edits, :map, default: %{"items" => []})
    field(:data, :map, default: %{})

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:conversation_id, :seq, :kind, :head_entry_id, :edits, :data])
    |> validate_required([:conversation_id, :seq, :kind, :data])
    |> foreign_key_constraint(:head_entry_id)
    |> unique_constraint([:conversation_id, :seq])
  end
end
