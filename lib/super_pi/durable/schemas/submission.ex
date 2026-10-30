defmodule SuperPi.Durable.Schemas.Submission do
  @moduledoc """
  Durable conversation submission lifecycle managed with `Fsmx`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @transitions %{
    "queued" => ["placed", "done", "failed", "aborted"],
    "placed" => ["done", "failed", "aborted"]
  }

  use Fsmx.Struct,
    state_field: :status,
    transitions: @transitions

  @type t :: %__MODULE__{}

  schema "submissions" do
    field(:conversation_id, :integer)
    field(:request_id, :string)
    field(:kind, :string, default: "input")
    field(:when_busy, :string, default: "follow_up")
    field(:status, :string, default: "queued")
    field(:entry_id, :integer)
    field(:payload, :map, default: %{})
    field(:settlement, :map)
    field(:created_seq, :integer)
    field(:updated_seq, :integer)

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(submission, attrs) do
    submission
    |> cast(attrs, [
      :conversation_id,
      :request_id,
      :kind,
      :when_busy,
      :status,
      :entry_id,
      :payload,
      :settlement,
      :created_seq,
      :updated_seq
    ])
    |> validate_required([
      :conversation_id,
      :kind,
      :when_busy,
      :status,
      :created_seq,
      :updated_seq
    ])
  end

  def transition_changeset(submission, _from, _to, params) do
    changeset(submission, params)
  end
end
