defmodule AshEnterprise.Mdm.Changes.AccountSealedFields do
  @moduledoc """
  Total accounting for a target's sealed fields, after `ash_mdm`'s validator.

  `AshMdm.Mapping.Validator` accounts every public **attribute** of the target:
  each must be mapped, or declined with `unmapped` and a because. A sealed value
  is not an attribute. `Canonical.Person`'s address is stored as ciphertext
  and read back as the `email` calculation
  (`AshEnterprise.Erasure.Calculations.Unseal`), so without this a mapping
  could leave the address unaccounted and still validate.

  This applies the same two checks to the target's sealed fields
  (`Unseal.sealed_fields/1`), in the same shape (`:unaccounted_target`,
  `:unmapped_without_because`), adds them to `validation_findings`, and
  keeps the mapping a draft when they are errors. It runs in a hook after the
  validator's own.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Erasure.Calculations.Unseal

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &account/1)
  end

  defp account(changeset) do
    fields = sealed_fields(Ash.Changeset.get_attribute(changeset, :target_resource))
    rules = rules(Ash.Changeset.get_attribute(changeset, :field_rules))
    direction = Ash.Changeset.get_attribute(changeset, :direction)

    case for(field <- fields, finding = problem(rules, direction, field), do: finding) do
      [] ->
        changeset

      problems ->
        findings = Ash.Changeset.get_attribute(changeset, :validation_findings) || %{}
        errors = Map.get(findings, :errors, []) ++ problems

        changeset
        |> Ash.Changeset.force_change_attribute(
          :validation_findings,
          findings |> Map.put(:errors, errors) |> Map.put_new(:warnings, [])
        )
        |> Ash.Changeset.force_change_attribute(:status, :draft)
    end
  end

  defp sealed_fields(target) when is_binary(target) do
    case :ash_mdm |> Application.get_env(:allowed_targets, %{}) |> Map.get(target) do
      nil -> []
      module -> Unseal.sealed_fields(module)
    end
  end

  defp sealed_fields(_target), do: []

  defp rules(rules) when is_list(rules), do: Enum.filter(rules, &is_map/1)
  defp rules(_rules), do: []

  # As the validator: an ingress rule accounts its target; an egress rule
  # accounts the golden field it reads (its path), or, `unmapped`, its target.
  defp problem(rules, direction, field) do
    name = to_string(field)

    rule =
      Enum.find(rules, fn rule ->
        key =
          if direction in [:egress, "egress"] and rule["op"] != "unmapped",
            do: rule["path"],
            else: rule["target"]

        key == name
      end)

    cond do
      is_nil(rule) ->
        %{check: :unaccounted_target, target: name}

      rule["op"] == "unmapped" and rule["because"] in [nil, ""] ->
        %{check: :unmapped_without_because, target: name}

      true ->
        nil
    end
  end
end
