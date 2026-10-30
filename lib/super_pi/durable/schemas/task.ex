defmodule SuperPi.Durable.Schemas.Task do
  @moduledoc """
  Persisted durable task state machine managed with `Fsmx` (`REQ-FSM-01`..`REQ-FSM-05`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @transitions %{
    "pending" => ["running", "aborted", "cancelled", "orphaned", "failed"],
    "running" => [
      "pending",
      "running",
      "waiting",
      "sleeping",
      "completing",
      "completed",
      "failed",
      "aborted",
      "cancelled"
    ],
    "waiting" => ["pending", "running", "completing", "completed", "failed", "aborted", "cancelled", "orphaned"],
    "sleeping" => ["pending", "running", "failed", "aborted", "cancelled", "orphaned"],
    "completing" => ["completed", "failed", "aborted"]
  }

  use Fsmx.Struct,
    state_field: :status,
    transitions: @transitions

  @type t :: %__MODULE__{}

  schema "tasks" do
    field :conversation_id, :integer
    field :owner_task_id, :integer
    field :kind, :string
    field :status, :string, default: "pending"
    field :phase, :string, default: "init"
    field :version, :integer, default: 1
    field :input, :map, default: %{}
    field :state, :map, default: %{"phase" => "init"}
    field :result, :map
    field :wait_policy, :string
    field :waiting_on_task_ids, :map, default: %{"ids" => []}
    field :sleep_until, :utc_datetime_usec
    field :attempt, :integer, default: 0
    field :owner_node, :string
    field :restart_limit, :integer, default: 5
    field :abandon_on_restart, :boolean, default: false
    field :abort_requested, :boolean, default: false
    field :background, :boolean, default: false
    field :created_seq, :integer
    field :updated_seq, :integer

    timestamps(type: :utc_datetime_usec)
  end

  @terminal_statuses ~w(completed failed aborted cancelled orphaned)

  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses

  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :conversation_id,
      :owner_task_id,
      :kind,
      :status,
      :phase,
      :version,
      :input,
      :state,
      :result,
      :wait_policy,
      :waiting_on_task_ids,
      :sleep_until,
      :attempt,
      :owner_node,
      :restart_limit,
      :abandon_on_restart,
      :abort_requested,
      :background,
      :created_seq,
      :updated_seq
    ])
    |> validate_required([:conversation_id, :kind, :status, :phase, :created_seq, :updated_seq])
  end

  def transition_changeset(task, _from, _to, params) do
    changeset(task, params)
  end
end
