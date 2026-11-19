defmodule AshEnterprise.Repo.Migrations.FixtureNewTableAltered do
  @moduledoc false
  use Ecto.Migration

  # The shape Ash codegen writes for tables that reference one another: create, then alter
  # the table it just created. No node running the previous release reads a table that did
  # not exist before this migration.
  def up do
    create table(:fx_fresh, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :count, :integer
    end

    alter table(:fx_fresh) do
      add :code, :text, null: false
    end

    alter table(:fx_fresh) do
      modify :count, :bigint
    end
  end

  def down do
    drop table(:fx_fresh)
  end
end
