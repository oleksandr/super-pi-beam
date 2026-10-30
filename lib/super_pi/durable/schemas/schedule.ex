defmodule SuperPi.Durable.Schemas.Schedule do
  @moduledoc """
  A scheduled or webhook-triggered run (`schedules` table).

  - `kind`: `"cron"` (fires at `cron` read in `timezone`) or `"webhook"` (fires on
    `POST /v1/triggers/:token`).
  - `mode`: where a run happens. `"fork"` branches the owning conversation at its latest entry,
    `"append"` adds the turn to the owning conversation, `"fresh"` starts a new conversation from
    the stored `agent` snapshot.
  - `status`: `"active"`, `"paused"` (three consecutive failed runs, see `SuperPi.Schedule`) or
    `"cancelled"`.
  - `next_fire_at`: the next scheduled minute of a cron schedule, moved forward by the tick.
  - `last_fire_at`: the latest scheduled minute that a run claimed. The claim is a conditional
    update on this column, which makes a run idempotent.

  Rows are keyed by `conversation_id`, not stored in a conversation document, so forking a
  conversation does not copy its schedules.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "schedules" do
    field :conversation_id, :integer
    field :kind, :string, default: "cron"
    field :name, :string
    field :cron, :string
    field :timezone, :string, default: "Etc/UTC"
    field :prompt, :string
    field :mode, :string, default: "fork"
    field :harness, :string
    field :agent, :map, default: %{}
    field :principal, :string, default: "anonymous"
    field :status, :string, default: "active"
    field :catch_up, :boolean, default: false
    field :token_hash, :string
    field :next_fire_at, :utc_datetime
    field :last_fire_at, :utc_datetime
    field :claimed_at, :naive_datetime
    field :consecutive_failures, :integer, default: 0
    field :last_task_id, :integer
    field :last_conversation_id, :integer
    field :last_error, :string

    timestamps(type: :utc_datetime_usec)
  end

  @kinds ~w(cron webhook)
  @modes ~w(fork append fresh)
  @statuses ~w(active paused cancelled)

  def kinds, do: @kinds
  def modes, do: @modes
  def statuses, do: @statuses

  @doc false
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [
      :conversation_id,
      :kind,
      :name,
      :cron,
      :timezone,
      :prompt,
      :mode,
      :harness,
      :agent,
      :principal,
      :status,
      :catch_up,
      :token_hash,
      :next_fire_at,
      :last_fire_at,
      :consecutive_failures,
      :last_task_id,
      :last_conversation_id,
      :last_error
    ])
    |> validate_required([:conversation_id, :kind, :prompt, :mode, :status])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:mode, @modes)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint(:token_hash)
  end
end
