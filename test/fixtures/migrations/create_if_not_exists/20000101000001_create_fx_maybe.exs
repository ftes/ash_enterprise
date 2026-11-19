defmodule AshEnterprise.Repo.Migrations.FixtureCreateIfNotExistsCreate do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:fx_maybe, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :count, :integer
    end
  end

  def down do
    drop table(:fx_maybe)
  end
end
