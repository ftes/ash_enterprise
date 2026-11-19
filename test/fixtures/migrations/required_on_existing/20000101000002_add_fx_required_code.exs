defmodule AshEnterprise.Repo.Migrations.FixtureRequiredOnExisting do
  @moduledoc false
  use Ecto.Migration

  # The table is an earlier migration's: an old node inserting without this column breaks.
  def up do
    alter table(:fx_required) do
      add :code, :text, null: false
    end
  end

  def down do
    alter table(:fx_required) do
      remove :code
    end
  end
end
