defmodule AshEnterprise.Repo.Migrations.FixtureDropColumn do
  @moduledoc false
  use Ecto.Migration

  # A contract step: an old node still selecting this column breaks on the new schema.
  def up do
    alter table(:fx_drop) do
      remove :legacy_name
    end
  end

  def down do
    alter table(:fx_drop) do
      add :legacy_name, :text
    end
  end
end
