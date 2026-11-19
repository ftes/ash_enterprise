defmodule AshEnterprise.Compliance.PolicyTest do
  @moduledoc """
  Publishing a policy: the bytes become an evidence document version, each publish of a
  key mints the next version, one version per key is current, and the same bytes mint
  nothing. All content here is synthetic.
  """

  use AshEnterprise.DataCase, async: true

  @moduletag :evidence

  import AshEnterprise.Test.DailyFixtures, only: [tenant!: 0, member!: 3]

  require Ash.Query

  alias AshEnterprise.Compliance
  alias AshEnterprise.Compliance.Policy
  alias AshEnterprise.Platform.AutomationPrincipal
  alias AshEnterprise.Security.ActorContext

  @v1 "SYNTHETIC acceptable use policy, version one."
  @v2 "SYNTHETIC acceptable use policy, version two."

  setup do
    %{admin: tenant!()}
  end

  defp opts(who), do: [actor: who.actor, tenant: who.tenant]

  defp publish!(who, key, content, title \\ "Acceptable use") do
    Compliance.publish_policy!(key, title, content, opts(who))
  end

  defp rows(who, key) do
    Policy
    |> Ash.Query.filter(policy_key == ^key)
    |> Ash.Query.sort(version: :asc)
    |> Ash.read!(opts(who))
  end

  defp sha(content), do: Base.encode16(:crypto.hash(:sha256, content), case: :lower)

  describe "refusals" do
    test "identical bytes mint no version", %{admin: admin} do
      first = publish!(admin, "acceptable-use", @v1)
      again = publish!(admin, "acceptable-use", @v1, "Acceptable use, retitled")

      assert again.id == first.id
      assert again.version == 1
      assert again.title == "Acceptable use"
      assert [%{version: 1, superseded_at: nil}] = rows(admin, "acceptable-use")
    end

    test "publishing a key twice leaves exactly one current row", %{admin: admin} do
      publish!(admin, "acceptable-use", @v1)
      publish!(admin, "acceptable-use", @v2)

      assert [%{version: 1, superseded_at: %DateTime{}}, %{version: 2, superseded_at: nil}] =
               rows(admin, "acceptable-use")

      assert [%{version: 2}] = Compliance.current_policies!(opts(admin))
    end

    test "another tenant cannot read or publish", %{admin: admin} do
      publish!(admin, "acceptable-use", @v1)
      other = tenant!()

      assert [] = Compliance.current_policies!(opts(other))
      assert nil == Compliance.current_policy!("acceptable-use", opts(other))

      # Naming the other tenant is refused outright.
      assert {:error, %Ash.Error.Forbidden{}} =
               Compliance.publish_policy("acceptable-use", "Taken", @v2,
                 actor: other.actor,
                 tenant: admin.tenant
               )

      # Naming the other tenant reads nothing either.
      assert {:ok, []} = Compliance.current_policies(actor: other.actor, tenant: admin.tenant)

      assert [%{version: 1}] = rows(admin, "acceptable-use")

      # The same bytes in the other tenant are that tenant's own version 1.
      theirs = publish!(other, "acceptable-use", @v1)
      assert theirs.version == 1
      assert theirs.organization_id == other.tenant
    end

    test "an unknown key has no current version", %{admin: admin} do
      publish!(admin, "acceptable-use", @v1)

      assert nil == Compliance.current_policy!("no-such-policy", opts(admin))
      assert [] = Compliance.policy_versions!("no-such-policy", opts(admin))
    end

    test "a refused publish leaves the prior version current", %{admin: admin} do
      first = publish!(admin, "acceptable-use", @v1)

      # A blank title is refused where it is stored, after v1 was superseded in the same
      # transaction: all of it rolls back.
      assert {:error, %Ash.Error.Invalid{}} =
               Compliance.publish_policy("acceptable-use", "", @v2, opts(admin))

      assert [%{id: id, version: 1, superseded_at: nil}] = rows(admin, "acceptable-use")
      assert id == first.id
      assert %{id: ^id} = Compliance.current_policy!("acceptable-use", opts(admin))
    end

    test "a key that is not a slug is Invalid", %{admin: admin} do
      for key <- ["Acceptable Use", "", "a/b"] do
        assert {:error, %Ash.Error.Invalid{}} =
                 Compliance.publish_policy(key, "Title", @v1, opts(admin))
      end

      assert [] = Compliance.current_policies!(opts(admin))
    end

    test "a user without the grant cannot publish, and an automation principal cannot either",
         %{admin: admin} do
      member = member!(admin, "No policies", [])

      assert {:error, %Ash.Error.Forbidden{}} =
               Compliance.publish_policy("acceptable-use", "Title", @v1, opts(member))

      # The principal acts for the administrator with the administrator's whole authority:
      # the grant is there, and still publishing is a person's own.
      principal =
        AutomationPrincipal.acting(
          AutomationPrincipal.recipe_runner(),
          admin.user.id,
          "policy-test",
          ActorContext.build(admin.user, tenant: admin.tenant)
        )

      assert {:error, %Ash.Error.Forbidden{}} =
               Compliance.publish_policy("acceptable-use", "Title", @v1,
                 actor: principal,
                 tenant: admin.tenant
               )

      assert [] = Compliance.current_policies!(opts(admin))
    end
  end

  describe "publishing" do
    test "version 1 records the document version and its hash", %{admin: admin} do
      policy = publish!(admin, "acceptable-use", @v1)

      assert policy.version == 1
      assert policy.sha256 == sha(@v1)
      assert %DateTime{} = policy.published_at
      assert policy.superseded_at == nil

      document =
        AshEvidence.Domain.get_document_version!(policy.document_version_id,
          tenant: admin.tenant
        )

      assert document.kind == "policy"
      assert document.sha256 == policy.sha256
      assert document.bytes == @v1
    end

    test "version 2 supersedes version 1 and leaves it as it was", %{admin: admin} do
      v1 = publish!(admin, "acceptable-use", @v1)
      v2 = publish!(admin, "acceptable-use", @v2, "Acceptable use, revised")

      assert v2.version == 2
      assert v2.document_version_id != v1.document_version_id

      [old, current] = rows(admin, "acceptable-use")
      assert old.id == v1.id
      assert old.sha256 == v1.sha256
      assert old.document_version_id == v1.document_version_id
      assert old.title == "Acceptable use"
      assert %DateTime{} = old.superseded_at
      assert current.id == v2.id

      assert %{id: id} = Compliance.current_policy!("acceptable-use", opts(admin))
      assert id == v2.id

      assert [%{version: 2}, %{version: 1}] =
               Compliance.policy_versions!("acceptable-use", opts(admin))
    end

    test "restoring earlier bytes is a new version over the same document", %{admin: admin} do
      v1 = publish!(admin, "acceptable-use", @v1)
      publish!(admin, "acceptable-use", @v2)
      v3 = publish!(admin, "acceptable-use", @v1)

      assert v3.version == 3
      assert v3.document_version_id == v1.document_version_id
      assert [%{version: 3}] = Compliance.current_policies!(opts(admin))
    end

    test "keys are independent and the current set is sorted by key", %{admin: admin} do
      publish!(admin, "privacy", "SYNTHETIC privacy policy.", "Privacy")
      publish!(admin, "acceptable-use", @v1)
      publish!(admin, "acceptable-use", @v2)

      assert [%{policy_key: "acceptable-use", version: 2}, %{policy_key: "privacy", version: 1}] =
               Compliance.current_policies!(opts(admin))
    end
  end
end
