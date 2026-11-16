defmodule AshEnterprise.Canonical.Calculations.PersonLabel do
  @moduledoc """
  How a `AshEnterprise.Canonical.Person` is named on a surface: their
  display name, else their address, else nil. `relationship:` names the
  belongs_to to read through (`:organizer`, `:sender`); without it, the
  person's own label (`Person.label`).

  A module calculation, not an expression: the address is sealed, so the
  database cannot read it (`AshEnterprise.Canonical.PersonSeal`). A related
  person is loaded under the reading actor's policies, so a correspondent
  the reader may not see is simply blank.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Platform.Calculations.RelatedField

  @impl true
  def init(opts) do
    if is_atom(opts[:relationship]),
      do: {:ok, opts},
      else: {:error, "relationship must be a relationship name"}
  end

  # The person is loaded in `calculate/3`, as the reader: a relationship
  # named here would be loaded as a calculation dependency, which Ash does
  # without authorization (see `AshEnterprise.Platform.Calculations.RelatedField`).
  @impl true
  def load(query, opts, _context) do
    case opts[:relationship] do
      nil -> [:name, :email]
      relationship -> RelatedField.source_attribute(query.resource, relationship)
    end
  end

  @impl true
  def calculate(records, opts, context) do
    case opts[:relationship] do
      nil -> Enum.map(records, &label/1)
      _relationship -> calculate_related(records, opts, context)
    end
  end

  defp calculate_related(records, opts, context) do
    with {:ok, loaded} <-
           RelatedField.load_related(records, opts[:relationship], [:name, :email], context) do
      {:ok, Enum.map(loaded, &label(Map.get(&1, opts[:relationship])))}
    end
  end

  @doc false
  def label(%Ash.NotLoaded{}), do: nil
  def label(%{name: name}) when is_binary(name) and name != "", do: name
  def label(%{email: email}) when not is_nil(email), do: to_string(email)
  def label(_person), do: nil
end
