defmodule SuperPi.Repo.Migrations.CreateDurableTables do
  use Ecto.Migration

  def up do
    create table(:record_ids, primary_key: false) do
      add :name, :string, primary_key: true
      add :seq, :bigint, null: false, default: 0
    end

    execute "INSERT INTO record_ids (name, seq) VALUES ('global_seq', 0)"

    create table(:conversations) do
      add :parent_conversation_id, references(:conversations, on_delete: :nothing)
      add :parent_entry_id, references(:entries, on_delete: :nothing)
      add :owner_kind, :string, null: false, default: "ownerless"
      add :owner_task_id, references(:tasks, on_delete: :nothing)
      add :created_seq, :bigint, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:conversations, [:parent_conversation_id])
    create index(:conversations, [:owner_task_id])

    create table(:entries) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :seq, :bigint, null: false
      add :kind, :string, null: false
      add :head_entry_id, references(:entries, on_delete: :nothing)
      add :edits, :map, null: false, default: %{"items" => []}
      add :data, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create index(:entries, [:conversation_id, :id])
    create index(:entries, [:conversation_id, :head_entry_id])
    create index(:entries, [:seq])
    create unique_index(:entries, [:conversation_id, :seq])

    create table(:tasks) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :owner_task_id, :bigint
      add :kind, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :phase, :string, null: false, default: "init"
      add :version, :integer, null: false, default: 1
      add :input, :map, null: false, default: %{}
      add :state, :map, null: false, default: %{"phase" => "init"}
      add :result, :map
      add :wait_policy, :string
      add :waiting_on_task_ids, :map, null: false, default: %{"ids" => []}
      add :sleep_until, :utc_datetime_usec
      add :attempt, :integer, null: false, default: 0
      add :restart_limit, :integer, null: false, default: 5
      add :abandon_on_restart, :boolean, null: false, default: false
      add :abort_requested, :boolean, null: false, default: false
      add :background, :boolean, null: false, default: false
      add :created_seq, :bigint, null: false
      add :updated_seq, :bigint, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:tasks, [:status])
    create index(:tasks, [:conversation_id, :status])
    create index(:tasks, [:owner_task_id])
    create index(:tasks, [:kind])

    create table(:submissions) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :request_id, :string
      add :kind, :string, null: false, default: "input"
      add :when_busy, :string, null: false, default: "follow_up"
      add :status, :string, null: false, default: "queued"
      add :entry_id, :bigint
      add :payload, :map, null: false, default: %{}
      add :settlement, :map
      add :created_seq, :bigint, null: false
      add :updated_seq, :bigint, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:submissions, [:conversation_id, :request_id])
    create index(:submissions, [:conversation_id, :status])

    create table(:documents) do
      add :kind, :string, null: false
      add :key, :string, null: false, default: ""
      add :scope_kind, :string, null: false
      add :scope_id, :bigint, null: false, default: 0
      add :history_policy, :string, null: false, default: "latest"
      add :fork_policy, :string, null: false, default: "current"
      add :created_seq, :bigint, null: false
      add :retired_seq, :bigint

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:documents, [:scope_kind, :scope_id, :kind, :key],
      where: "retired_seq IS NULL",
      name: :documents_active_unique_index
    )
    create index(:documents, [:created_seq, :retired_seq])

    create table(:document_revisions) do
      add :document_id, references(:documents, on_delete: :delete_all), null: false
      add :seq, :bigint, null: false
      add :version, :integer, null: false, default: 1
      add :is_checkpoint_base, :boolean, null: false, default: false
      add :value, :map
      add :ops, :map, null: false, default: %{"ops" => []}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:document_revisions, [:document_id, :seq])
    create index(:document_revisions, [:document_id, :is_checkpoint_base, :seq])

    Oban.Migrations.up()
  end

  def down do
    Oban.Migrations.down()

    drop table(:document_revisions)
    drop table(:documents)
    drop table(:submissions)
    drop table(:tasks)
    drop table(:entries)
    drop table(:conversations)
    drop table(:record_ids)
  end
end
