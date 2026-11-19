defmodule AshEnterprise.Repo.Migrations.FixtureRequiredOnExistingCreate do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:fx_required, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
    end
  end

  def down do
    drop table(:fx_required)
  end
end
