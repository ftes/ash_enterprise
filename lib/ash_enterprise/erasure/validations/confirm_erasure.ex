defmodule AshEnterprise.Erasure.Validations.ConfirmErasure do
  @moduledoc """
  Erasing a person is irreversible, so the address has to be given twice: `confirm`
  must equal `email`, case and surrounding space aside, as the blind index compares
  them (`AshEnterprise.Erasure.BlindIndex.normalize/1`). A blank address names nobody
  and is refused.

  The error names the field, never the value.
  """

  use Ash.Resource.Validation

  alias AshEnterprise.Erasure.BlindIndex

  @impl true
  def validate(changeset, _opts, _context) do
    email = normalized(Ash.Changeset.get_argument(changeset, :email))
    confirm = normalized(Ash.Changeset.get_argument(changeset, :confirm))

    cond do
      email == "" ->
        {:error, field: :email, message: "must be an address"}

      confirm != email ->
        {:error, field: :confirm, message: "must repeat the address, to confirm whom to erase"}

      true ->
        :ok
    end
  end

  defp normalized(nil), do: ""
  defp normalized(value), do: BlindIndex.normalize(value)
end
