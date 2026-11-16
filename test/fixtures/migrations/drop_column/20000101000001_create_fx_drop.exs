defmodule AshEnterprise.Repo.Migrations.FixtureDropColumnCreate do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:fx_drop, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :legacy_name, :text
    end
  end

  def down do
    drop table(:fx_drop)
  end
end
