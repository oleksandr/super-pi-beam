defmodule SuperPi.Durable.Schemas.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "conversations" do
    field :parent_conversation_id, :integer
    field :parent_entry_id, :integer
    field :owner_kind, :string, default: "ownerless"
    field :owner_task_id, :integer
    field :created_seq, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @valid_owner_kinds ~w(ownerless task)

  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :id,
      :parent_conversation_id,
      :parent_entry_id,
      :owner_kind,
      :owner_task_id,
      :created_seq
    ])
    |> validate_required([:owner_kind, :created_seq])
    |> validate_inclusion(:owner_kind, @valid_owner_kinds)
    |> foreign_key_constraint(:parent_entry_id)
    |> foreign_key_constraint(:owner_task_id)
  end
end
