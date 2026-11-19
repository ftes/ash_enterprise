defmodule AshEnterprise.Signatures.SignerEvent do
  @moduledoc """
  One thing that happened on a signature request: the `AshSignatures.SignerEvent` fragment
  on the platform base, in table `signature_signer_events`. Append-only: the fragment has
  only `record` and `read`, and this resource adds no update or destroy (the package's
  rule 5).

  `record` is the package's own write, made by the act it follows (a person signing, the
  job runner reminding) with `authorize?: false`; it is machinery-only, so no grant can
  write an event directly. A signer reads the events on their own row
  (`AshEnterprise.Signatures.Checks.SignerReach`); people who manage requests read them
  through a grant.

  ## Sealing

  `ip_address`, `user_agent` and `reason` (`AshSignatures.payload_fields(:signer_event)`)
  are cloaked and sealed under the signer's erasure scope, copied from the signer row
  (`AshEnterprise.Signatures.Changes.ScopeFromSigner`). The event hash is taken from them
  before they are sealed, so `event_hash` covers them and outlives them: once the scope is
  shredded they read as `AshEnterprise.Erasure.Shredded` and the hash, type, route, the
  SHA-256 of what was shown and `occurred_at` stay.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Signatures,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    machinery_only: [:record],
    extra_grants: [{AshEnterprise.Signatures.Checks.SignerReach, via: :signer_event}],
    extra_extensions: [AshCloak],
    fragments: [AshSignatures.SignerEvent]

  postgres do
    table "signature_signer_events"
    repo AshEnterprise.Repo

    references do
      reference :request, on_delete: :restrict
      reference :signer, on_delete: :restrict
      reference :erasure_scope, on_delete: :restrict
    end
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes AshSignatures.payload_fields(:signer_event)
    encrypt_nil?(false)
  end

  changes do
    change AshEnterprise.Signatures.Changes.ScopeFromSigner, on: [:create]

    change {AshEnterprise.Erasure.Changes.SealUnderScope,
            fields: AshSignatures.payload_fields(:signer_event)},
           on: [:create]
  end

  relationships do
    belongs_to :request, AshEnterprise.Signatures.Request do
      public? true
      define_attribute? false
    end

    belongs_to :signer, AshEnterprise.Signatures.Signer do
      public? true
      define_attribute? false
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      public? true

      description "The signer's erasure scope, which the event's personal fields are sealed under."
    end
  end

  calculations do
    calculate :recorded?,
              :boolean,
              expr(is_nil(erasure_scope_id) or erasure_scope.status == :active) do
      public? true

      description "False once the signer's erasure scope is shredded: the personal fields then read as erased."
    end
  end

  # ADR 0032: how these columns may leave production in a copy (greenmask.yml).
  greenmask do
    keep(:encrypted_ip_address,
      because:
        "ciphertext sealed under an erasure-scope key; a copy's scope keys are replaced (Erasure.Key.wrapped_key), so it cannot be opened there"
    )

    keep(:encrypted_user_agent,
      because:
        "ciphertext sealed under an erasure-scope key; a copy's scope keys are replaced (Erasure.Key.wrapped_key), so it cannot be opened there"
    )

    keep(:encrypted_reason,
      because:
        "ciphertext sealed under an erasure-scope key; a copy's scope keys are replaced (Erasure.Key.wrapped_key), so it cannot be opened there"
    )
  end
end
