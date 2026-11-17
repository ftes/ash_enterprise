defmodule AshEnterprise.Erasure.BlindIndex do
  @moduledoc """
  A blind index: a keyed digest of a sealed value that lets the database find
  and deduplicate a row by that value without holding it (ADR 0024).

  `AshEnterprise.Canonical.Person` seals a correspondent's address under the
  person's own erasure scope. Sealed values are randomized ciphertext, so
  they cannot be an upsert identity or a lookup key. The blind index can:

      of(tenant, email) = HMAC-SHA256(key, "v1" <> 0 <> tenant <> 0 <> normalize(email))

  ## Why this key

  The key is derived from the erasure master key
  (`AshEnterprise.Erasure.Crypto.master_key!/0`) under its own label, so it
  is a production secret of the master key's class and never the same bytes
  as any wrapping or sealing key. It is deliberately **not** derived from the
  endpoint's `secret_key_base`: rotating that (a routine act after a session
  leak) would orphan every identity at once. It is not scope-dependent
  either, because the index must find a person before their scope is known.

  Consequences, recorded in `docs/runbooks/crypto-shredding.md`:

    * an erased person's index value does not become unreadable when their
      scope is shredded, because the key is not the scope's. Erasing the
      person (`AshEnterprise.Erasure.PersonErasure`) therefore also clears
      the column (`email_bidx`) on the row; the index alone is a keyed hash
      and names nobody without the master key;
    * master-key rotation is not built. When it is, it must recompute every
      index value, because the derived key changes with the master key.

  ## Why the tenant is in the input

  The same address in two tenants gets two different index values, so a
  reader of the table cannot link one person across organizations by
  comparing the column. Uniqueness is per tenant anyway.

  ## Normalization

  Trimmed and lowercased, matching the case-insensitive `ci_string` the
  address used to be stored as: `Ann@X.io` and `ann@x.io` are one person.
  """

  alias AshEnterprise.Erasure.Crypto

  @label "blind_index/canonical_person_email/v1"

  @doc """
  The blind index of `email` in `tenant`, as 32 raw bytes, or nil for a
  blank or nil address.
  """
  @spec of(term(), String.t() | Ash.CiString.t() | nil) :: binary() | nil
  def of(_tenant, nil), do: nil

  def of(tenant, email) do
    case normalize(email) do
      "" -> nil
      normalized -> :crypto.mac(:hmac, :sha256, key!(), ["v1", 0, tenant!(tenant), 0, normalized])
    end
  end

  @doc "The blind index of each non-blank address in `emails`, deduplicated."
  @spec all(term(), [String.t() | Ash.CiString.t() | nil]) :: [binary()]
  def all(tenant, emails) do
    emails |> Enum.map(&of(tenant, &1)) |> Enum.reject(&is_nil/1) |> Enum.uniq()
  end

  @doc "The normalized form the index is computed over: trimmed and lowercased."
  @spec normalize(String.t() | Ash.CiString.t()) :: String.t()
  def normalize(email), do: email |> to_string() |> String.trim() |> String.downcase()

  # The index key. Derived on every call, like every other key here: the
  # master key is configuration, and a cached derivative would outlive a
  # configuration change in a running node.
  defp key!, do: Crypto.derive_key(Crypto.master_key!(), @label)

  defp tenant!(nil), do: raise(ArgumentError, "a blind index needs the tenant it is unique in")
  defp tenant!(tenant) when is_binary(tenant), do: tenant

  defp tenant!(tenant),
    do: tenant |> Ash.ToTenant.to_tenant(AshEnterprise.Canonical.Person) |> to_string()
end
