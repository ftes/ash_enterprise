defmodule AshEnterprise.Signatures.Completion do
  @moduledoc """
  The one record a completed signature request ends in: the `AshSignatures.Completion`
  fragment on the platform base, in table `signature_completions`. Append-only: `record`
  and `read` only (the package's rule 5).

  `record` holds the request, its documents' SHA-256s, its signers by reference, every
  event's hash in order and the tenant's audit chain head
  (`AshEnterprise.Signatures.ChainHead`); `record_hash` is the SHA-256 of its canonical
  JSON. Nothing in it is personal data, so it survives an erasure whole.

  `record` is the package's write when a request completes, made with `authorize?: false`
  by the act that completed it; it is machinery-only, so no grant writes a completion
  directly. A signer reads the completion of a request they are asked on
  (`AshEnterprise.Signatures.Checks.SignerReach`).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Signatures,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    machinery_only: [:record],
    extra_grants: [{AshEnterprise.Signatures.Checks.SignerReach, via: :completion}],
    fragments: [AshSignatures.Completion]

  postgres do
    table "signature_completions"
    repo AshEnterprise.Repo

    references do
      reference :request, on_delete: :restrict
    end
  end

  # ADR 0032: how these columns may leave production in a copy (greenmask.yml).
  greenmask do
    keep(:record,
      because:
        "the completion record names the request, its documents and signers by id and holds hashes, roles, statuses and times; no personal field is in it (ash_signatures rule 6), and its record_hash must still verify"
    )
  end

  relationships do
    belongs_to :request, AshEnterprise.Signatures.Request do
      public? true
      define_attribute? false
    end
  end
end
