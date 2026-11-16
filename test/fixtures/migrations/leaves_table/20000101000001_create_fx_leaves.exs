defmodule AshEnterprise.Repo.Migrations.FixtureLeavesTable do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:fx_leaves, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
    end
  end

  # A down that runs and does nothing: the schema after the rollback is not the schema
  # before the migration, which only the up/down snapshot comparison can see.
  def down do
    :ok
  end
end
