defmodule SuperPi.Repo.Migrations.CreateArtifacts do
  use Ecto.Migration

  # Files that an agent saves on purpose, so they outlive a scratch workspace and a node.
  def change do
    create table(:artifacts) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :name, :string, size: 255, null: false
      add :content_type, :string, null: false, default: "application/octet-stream"
      add :size, :bigint, null: false
      add :data, :binary, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:artifacts, [:conversation_id, :name])
  end
end
