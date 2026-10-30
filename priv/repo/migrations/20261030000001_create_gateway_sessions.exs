defmodule SuperPi.Repo.Migrations.CreateGatewaySessions do
  use Ecto.Migration

  # Maps a client's `x-session-id` (per principal) to a conversation. It lives in the database so
  # a restart, or another node, finds the same conversation.
  def change do
    create table(:gateway_sessions) do
      add :principal, :string, null: false
      add :session_id, :string, null: false
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :last_used_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gateway_sessions, [:principal, :session_id])
    create index(:gateway_sessions, [:last_used_at])
    create index(:gateway_sessions, [:conversation_id])
  end
end
