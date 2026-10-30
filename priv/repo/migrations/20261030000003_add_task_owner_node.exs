defmodule SuperPi.Repo.Migrations.AddTaskOwnerNode do
  use Ecto.Migration

  # The node whose machine runs the task. Open-time recovery leaves a task alone when its owner
  # node is another live node.
  def change do
    alter table(:tasks) do
      add :owner_node, :string
    end
  end
end
