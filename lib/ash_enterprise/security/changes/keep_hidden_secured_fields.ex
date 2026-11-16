defmodule AshEnterprise.Security.Changes.KeepHiddenSecuredFields do
  @moduledoc """
  An update leaves a secured column as it is when its writer cannot see it and sends back
  what they were shown.

  A form is filled from the record as its reader reads it, so a secured column the reader
  has no grant for (`AshEnterprise.Platform.Resource`'s `secured_fields`, ADR 0073) arrives
  in the form as what stood in for it: `nil` on a JSON wire, an empty field, or, where a
  surface serializes a struct it does not know by inspecting it (`ash_a2ui` does), the
  inspected `%Ash.ForbiddenField{}`. Submitting that form unchanged would write the
  stand-in over the stored value. So for each secured column an update changes, when the
  writer does not see the column on this row and the new value is one of those stand-ins,
  the change is dropped and the stored value stays.

  Any other value is written, as before: a write to a secured column follows the row's
  grant (ADR 0073, "Reads only"). The grant is read from the precomputed
  `AshEnterprise.Security.ActorContext`: no query.
  """

  use Ash.Resource.Change

  alias AshEnterprise.Security.Checks.RoleGrant

  # What `inspect/1` makes of an `%Ash.ForbiddenField{}`.
  @inspected "#Ash.ForbiddenField<"

  # It reads the actor's precomputed context and the changeset, never the clock.
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, context), do: keep(changeset, Map.get(context, :actor))

  @impl true
  def atomic(changeset, _opts, context), do: {:ok, keep(changeset, Map.get(context, :actor))}

  @doc "Whether `value` is what a reader without the column's grant was shown for it."
  @spec stand_in?(term()) :: boolean()
  def stand_in?(nil), do: true
  def stand_in?(%Ash.ForbiddenField{}), do: true
  def stand_in?(value) when is_binary(value), do: String.trim(value) == "" or inspected?(value)
  def stand_in?(_value), do: false

  defp inspected?(value), do: String.starts_with?(value, @inspected)

  defp keep(changeset, actor) do
    changeset.resource
    |> secured_fields()
    |> Enum.reduce(changeset, fn field, changeset ->
      if changing_to_stand_in?(changeset, field) and not sees?(actor, changeset, field),
        do: drop(changeset, field),
        else: changeset
    end)
  end

  defp changing_to_stand_in?(changeset, field) do
    Ash.Changeset.changing_attribute?(changeset, field) and
      stand_in?(Ash.Changeset.get_attribute(changeset, field))
  end

  defp drop(changeset, field) do
    changeset
    |> Ash.Changeset.clear_change(field)
    |> Map.update!(:atomics, &Keyword.delete(&1, field))
  end

  # The column's grant on this row. A grant below `:global` is evaluated against the row
  # when the row is loaded; when it cannot be (an atomic update), the column counts as
  # hidden, so the stand-in is dropped and nothing is lost.
  defp sees?(actor, changeset, field) do
    authorizer = %{resource: changeset.resource, action: changeset.action}

    case RoleGrant.filter(actor, authorizer, field: field) do
      true ->
        true

      false ->
        false

      visible ->
        case Ash.Expr.eval(visible,
               record: changeset.data,
               resource: changeset.resource,
               actor: actor,
               unknown_on_unknown_refs?: true
             ) do
          {:ok, true} -> true
          _hidden_or_unknown -> false
        end
    end
  end

  defp secured_fields(resource) do
    if AshEnterprise.Platform.SystemAttributes in Spark.extensions(resource),
      do: Spark.Dsl.Extension.get_opt(resource, [:platform], :secured_fields, []),
      else: []
  end
end
