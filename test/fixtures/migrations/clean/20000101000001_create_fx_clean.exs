defmodule AshEnterprise.Repo.Migrations.FixtureCleanCreate do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:fx_clean, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
    end
  end

  def down do
    drop table(:fx_clean)
  end
end
