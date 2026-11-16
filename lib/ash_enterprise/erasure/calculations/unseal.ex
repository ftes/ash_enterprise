defmodule AshEnterprise.Erasure.Calculations.Unseal do
  @moduledoc """
  Reads a value sealed under its erasure scope, for a whole page at once.

      calculate :email, :ci_string,
                {AshEnterprise.Erasure.Calculations.Unseal,
                 field: :encrypted_email, type: :ci_string}

  `type` (and optional `constraints`) must be the calculation's own type: the
  sealed value is loaded through it.

  The stored form is `ash_cloak`'s, byte for byte: base64 of the sealed
  binary, whose plaintext is the value serialized as `ash_cloak` serializes
  it (`AshEnterprise.Erasure.Changes.SealUnderScope`). So everything that
  reads `ash_cloak` columns (the vault, the erasure sweeps, the audit copy)
  reads these the same way.

  What differs from `ash_cloak`'s own decrypt calculation is the batching:
  `ash_cloak` opens one value at a time through its vault, which costs one
  key lookup per value. This calculation hands the page's values to
  `AshEnterprise.Erasure.Keyring.open_many!/1`, which fetches every scope's
  key in one query. A shredded scope reads as `AshEnterprise.Erasure.Shredded`;
  a lost or wrong key raises, as it does everywhere else.
  """

  use Ash.Resource.Calculation

  alias AshEnterprise.Erasure.Keyring

  @doc """
  The public calculations of `resource` that read a sealed value back
  (`Canonical.Person`'s `email`): fields a reader and a mapping see as the
  resource's own, though they are not attributes.
  """
  @spec sealed_fields(Ash.Resource.t()) :: [atom()]
  def sealed_fields(resource) do
    for %{public?: true, calculation: {__MODULE__, _opts}, name: name} <-
          Ash.Resource.Info.calculations(resource),
        do: name
  end

  @impl true
  def init(opts) do
    if is_atom(opts[:field]) and not is_nil(opts[:field]) and not is_nil(opts[:type]),
      do: {:ok, opts},
      else: {:error, "field must name the encrypted_* attribute to unseal, and type its type"}
  end

  @impl true
  def load(_query, opts, _context), do: [opts[:field]]

  @impl true
  def calculate(records, opts, _context) do
    type = Keyword.fetch!(opts, :type)
    constraints = Keyword.get(opts, :constraints, [])

    sealed =
      for record <- records,
          value = Map.get(record, opts[:field]),
          not is_nil(value),
          do: Base.decode64!(value)

    opened =
      sealed |> Keyring.open_many!() |> Enum.zip(sealed) |> Map.new(fn {o, s} -> {s, o} end)

    Enum.map(records, fn record ->
      case Map.get(record, opts[:field]) do
        nil ->
          nil

        value ->
          value |> Base.decode64!() |> then(&Map.fetch!(opened, &1)) |> read(type, constraints)
      end
    end)
  end

  defp read({:shredded, marker}, _type, _constraints), do: marker

  defp read({:ok, plaintext}, type, constraints) do
    plaintext |> safe_binary_to_term() |> deserialize(type, constraints)
  end

  # As `ash_cloak`'s decrypt: refuse the compressed format, and never intern
  # an atom the ciphertext names.
  defp safe_binary_to_term(<<131, 80, _rest::binary>>),
    do: raise(ArgumentError, "refusing to decode a compressed term during unsealing")

  defp safe_binary_to_term(binary), do: Ash.Helpers.non_executable_binary_to_term(binary, [:safe])

  defp deserialize({:__ash_cloak__, dumped}, type, constraints) do
    case Ash.Type.cast_from_embedded(type, dumped, constraints) do
      {:ok, value} -> value
      other -> raise ArgumentError, "cannot load the unsealed value: #{inspect(other)}"
    end
  end

  defp deserialize(value, _type, _constraints), do: value
end
