defmodule AshEnterprise.Anonymization.GreenmaskConfigTest do
  @moduledoc """
  ADR 0032: the greenmask config is generated from the `greenmask` blocks, and
  every attribute that could name a person has a position in it. `mix
  ash_greenmask.gen.config --check` gates the committed file in CI; these
  tests say what the file must contain, and that the gates refuse a gap.
  """
  use ExUnit.Case, async: true

  alias AshEnterprise.Governance.DataInventory
  alias AshGreenmask.Generator
  alias AshGreenmask.Info

  @root Path.expand("../../..", __DIR__)

  defmodule Fixtures.Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      resource AshEnterprise.Anonymization.GreenmaskConfigTest.Fixtures.Uncovered
      resource AshEnterprise.Anonymization.GreenmaskConfigTest.Fixtures.UnflaggedPersonal
    end
  end

  defmodule Fixtures.Uncovered do
    @moduledoc false
    use Ash.Resource,
      domain: AshEnterprise.Anonymization.GreenmaskConfigTest.Fixtures.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshGreenmask.Resource]

    postgres do
      table "greenmask_fixture_uncovered"
      repo AshEnterprise.Repo
      migrate? false
    end

    attributes do
      uuid_primary_key :id
      attribute :secret, :string, sensitive?: true
    end
  end

  defmodule Fixtures.UnflaggedPersonal do
    @moduledoc false
    use Ash.Resource,
      domain: AshEnterprise.Anonymization.GreenmaskConfigTest.Fixtures.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshGreenmask.Resource]

    postgres do
      table "greenmask_fixture_personal"
      repo AshEnterprise.Repo
      migrate? false
    end

    attributes do
      uuid_primary_key :id
      attribute :contact_email, :string
    end
  end

  defp domains, do: Application.fetch_env!(:ash_enterprise, :ash_domains)

  defp options do
    [
      strict?: Application.fetch_env!(:ash_greenmask, :strict?),
      layout: Application.fetch_env!(:ash_greenmask, :layout),
      default_schema: Application.fetch_env!(:ash_greenmask, :default_schema)
    ]
  end

  # Personal-looking attributes (the data inventory's heuristic) on a stored
  # resource whose block neither transforms nor keeps them, nor excludes the rows.
  defp without_position(resources) do
    for resource <- resources,
        Ash.Resource.Info.data_layer(resource) == AshPostgres.DataLayer,
        is_nil(Info.exclude_data(resource)),
        attribute <- Ash.Resource.Info.attributes(resource),
        DataInventory.looks_personal?(attribute.name),
        not positioned?(resource, attribute.name) do
      {resource, attribute.name}
    end
  end

  defp positioned?(resource, name) do
    Enum.any?(Info.transforms(resource), &(&1.attribute == name)) or
      Enum.any?(Info.keeps(resource), &(&1.attribute == name))
  end

  describe "refusals" do
    test "a stored resource with a sensitive attribute and no position is a generation error" do
      assert {:error, [reason]} = Generator.build([Fixtures.Domain], options())
      assert reason =~ "#{inspect(Fixtures.Uncovered)}: :secret is sensitive"
    end

    test "a personal-looking attribute with no position is reported" do
      assert without_position([Fixtures.UnflaggedPersonal]) == [
               {Fixtures.UnflaggedPersonal, :contact_email}
             ]
    end
  end

  test "the config is strict and is the dump section greenmask reads" do
    assert options() == [strict?: true, layout: :config, default_schema: "public"]
  end

  test "every sensitive? attribute across the domains has a transform or a keep with a reason" do
    assert {:ok, _document, residuals} = Generator.build(domains(), options())

    for line <- residuals do
      [_position, because] = String.split(line, " — ", parts: 2)
      assert String.length(because) > 20, "a keep with no real reason: #{line}"
    end
  end

  test "every looks-personal attribute in the data inventory has a greenmask position" do
    assert without_position(DataInventory.resources()) == []
  end

  test "Erasure.Key.wrapped_key is transformed, never kept" do
    resource = AshEnterprise.Erasure.Key

    assert nil == Info.exclude_data(resource)

    assert [%{transformer: :replace}] =
             Enum.filter(Info.transforms(resource), &(&1.attribute == :wrapped_key))

    refute Enum.any?(Info.keeps(resource), &(&1.attribute == :wrapped_key))
  end

  test "no production password hash and no address reaches a copy" do
    transforms = Map.new(Info.transforms(AshEnterprise.Accounts.User), &{&1.attribute, &1})

    assert %{transformer: :replace} = transforms.hashed_password
    assert %{transformer: :random_email, options: options} = transforms.email
    assert options[:engine] == "hash"
    assert options[:domains] == ["example.com"]
  end

  test "the committed greenmask.yml equals the generator output, and its residuals header names the audit tables and large objects" do
    assert {:ok, document, residuals} = Generator.build(domains(), options())
    rendered = document |> Generator.render(residuals) |> IO.iodata_to_binary()

    assert File.read!(Path.join(@root, "greenmask.yml")) == rendered,
           "greenmask.yml has drifted: run `mix ash_greenmask.gen.config` and commit it"

    excluded = get_in(document, ["dump", "pg_dump_options", "exclude-table-data"])
    assert "public.audit_events" in excluded
    assert "public.audit_event_archive" in excluded
    assert get_in(document, ["dump", "pg_dump_options", "no-blobs"]) == true

    assert rendered =~ "#{inspect(AshEnterprise.Audit.EventLog)}: rows not copied (exclude_data)"

    assert rendered =~
             "#{inspect(AshEnterprise.Audit.ArchivedEvent)}: rows not copied (exclude_data)"

    assert rendered =~ "Large objects are not copied"
    assert rendered =~ "GREENMASK_GLOBAL_SALT"
    refute rendered =~ ~r/GREENMASK_GLOBAL_SALT\s*[:=]\s*\S/
  end
end
