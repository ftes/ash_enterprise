defmodule AshEnterprise.Repo.Migrations.FixtureCreateIfNotExists do
  @moduledoc false
  use Ecto.Migration

  # CREATE TABLE IF NOT EXISTS does nothing here, because the table is already there:
  # the ALTER that follows changes a table an old node reads.
  def up do
    create_if_not_exists table(:fx_maybe, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :count, :integer
    end

    alter table(:fx_maybe) do
      modify :count, :bigint
    end
  end

  def down do
    alter table(:fx_maybe) do
      modify :count, :integer
    end
  end
end
