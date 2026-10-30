defmodule SuperPi.Repo.Migrations.CreateSchedules do
  use Ecto.Migration

  # Scheduled and webhook-triggered runs. One row per schedule, keyed by the conversation that
  # created it (a fork does not copy it). Adapter-neutral: no JSON operators, no partial indexes.
  def change do
    create table(:schedules) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :kind, :string, null: false, default: "cron"
      add :name, :string
      add :cron, :string
      add :timezone, :string, null: false, default: "Etc/UTC"
      add :prompt, :text, null: false
      add :mode, :string, null: false, default: "fork"
      add :harness, :string
      add :agent, :map, null: false, default: %{}
      add :principal, :string, null: false, default: "anonymous"
      add :status, :string, null: false, default: "active"
      add :catch_up, :boolean, null: false, default: false
      # SHA-256 of the webhook token; the token itself is shown once and never stored.
      add :token_hash, :string
      add :next_fire_at, :utc_datetime
      # Latest scheduled minute that a run claimed. The claim compares against it.
      add :last_fire_at, :utc_datetime
      # Database clock at the claim. Informational: clock skew between nodes cannot affect it.
      add :claimed_at, :naive_datetime
      add :consecutive_failures, :integer, null: false, default: 0
      # Task of the latest run that the tick has not accounted for yet.
      add :last_task_id, :integer
      add :last_conversation_id, :integer
      add :last_error, :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:schedules, [:conversation_id])
    create index(:schedules, [:kind, :status, :next_fire_at])
    create unique_index(:schedules, [:token_hash])
  end
end
