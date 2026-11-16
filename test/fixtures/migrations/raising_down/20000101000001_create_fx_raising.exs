defmodule AshEnterprise.Repo.Migrations.FixtureRaisingDown do
  @moduledoc false
  use Ecto.Migration

  def up do
    create table(:fx_raising, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
    end
  end

  # A down that cannot be run: the round trip must fail and name this version.
  def down do
    raise "this down was never written"
  end
end
