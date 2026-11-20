defmodule AshEnterprise.Signatures.Signer do
  @moduledoc """
  One person asked to sign or acknowledge a request: the `AshSignatures.Signer` fragment on
  the platform base, in table `signature_signers`.

  ## A signer is a user

  `user_id` names the person, a user of the organization. `add_person` is how a signer is
  added: it takes the request, role, order and user, and copies the person's name and email
  from their account, as they stood when they were asked. The fragment's own `add`, which
  takes a name and email and no user, is closed (machinery-only) and refuses a row without
  `user_id`.

  ## Who may do what

    * **The person, on their own row only.** `view`, `consent`, `sign`, `decline` and
      `request_changes` are reached by one grant path, the signer's own row
      (`AshEnterprise.Signatures.Checks.SignerReach`: `user_id` is the acting person), and
      are `human_only`: no bypass reaches them, and no automation principal does, whatever
      it is granted. Signing is a person's act (the package's rule 4). A second policy on
      those five actions has that one path only, so a role granting writes on signers (an
      administrator's) does not let anyone act for another person. Reads of their own rows
      go through the same check. Another person's row is not theirs to read or act on.
    * **The job runner.** `remind` is machinery-only: a reminder is the host's schedule,
      not anyone's choice. It records the `reminded` event and sends the person a message
      at their account's address (`AshEnterprise.Signatures.Changes.DeliverReminder`). So
      are `notify` and `withdraw`, which the package writes itself when a request is sent
      or ends.
    * **People who manage requests** read and add signers through a grant on this
      resource, as on any other.

  ## Sealing

  `name` and `email` (`AshSignatures.payload_fields(:signer)`) are cloaked and sealed under
  the person's own erasure scope (`data_subject`, the ref
  `AshEnterprise.Execution.Changes.SealingScope.scope_ref/1` names for the user: the one
  scope per person that erasing a person reaches,
  `AshEnterprise.Erasure.PersonErasure`). Once it is shredded they read as
  `AshEnterprise.Erasure.Shredded` and `recorded?` is false; the role, order, status, times
  and `shown_sha256` stay, as do the events' hashes and the completion record.

  Organization-owned (the organization asks), the fragment's state machine instead of the
  base lifecycle, and no soft delete.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Signatures,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    human_only: [:view, :consent, :sign, :decline, :request_changes],
    machinery_only: [:add, :remind, :notify, :withdraw],
    extra_grants: [
      {AshEnterprise.Signatures.Checks.SignerReach,
       via: :signer,
       actions: [
         :read,
         :mine,
         :awaiting_me,
         :naming_version,
         :view,
         :consent,
         :sign,
         :decline,
         :request_changes
       ]}
    ],
    extra_extensions: [AshCloak, AshAgent.Effects],
    fragments: [AshSignatures.Signer]

  postgres do
    table "signature_signers"
    repo AshEnterprise.Repo

    references do
      reference :request, on_delete: :restrict
      reference :user, on_delete: :restrict
      reference :erasure_scope, on_delete: :restrict
    end
  end

  signatures do
    request AshEnterprise.Signatures.Request
  end

  cloak do
    vault({AshEnterprise.Erasure.Vault, :resolve, []})
    attributes AshSignatures.payload_fields(:signer)
    encrypt_nil?(false)
  end

  # Open-world: a reminder sends the person a message outside the application
  # (`AshEnterprise.Signatures.Changes.DeliverReminder`).
  effects do
    action :remind,
      kind: :edit,
      read_only?: false,
      destructive?: false,
      idempotent?: false,
      open_world?: true,
      approval: :none,
      intent: :execute
  end

  actions do
    read :mine do
      description "The person's own signer rows, newest first: every request they were asked on."
      filter expr(user_id == ^actor(:id))
      prepare build(sort: [inserted_at: :desc, id: :desc])
    end

    read :awaiting_me do
      description "The person's own signer rows that are waiting on them: notified or viewed."
      filter expr(user_id == ^actor(:id) and status in [:notified, :viewed])
      prepare build(sort: [notified_at: :asc, id: :asc])
    end

    read :naming_version do
      description "The person's own signer rows on requests that name one document version."

      argument :source_version_id, :uuid, allow_nil?: false

      filter expr(
               user_id == ^actor(:id) and
                 exists(request.documents, source_version_id == ^arg(:source_version_id))
             )
    end

    create :add_person do
      description "Adds a user of the organization as a signer of a draft request."
      accept [:request_id, :role, :order, :user_id]

      # Set from the person's account by `FromUser`, never from input, and sealed.
      argument :email, :string, public?: false, sensitive?: true

      validate AshSignatures.Validations.RequestIsDraft
      change AshEnterprise.Signatures.Changes.FromUser
    end
  end

  # The person's acts have one more policy, with one grant path: the row is the acting
  # person's own. Every applicable policy must pass, so a role that grants writes on
  # signers (an administrator's) still cannot view, consent, sign or decline for someone
  # else. No `forbid_if`: like the shred policy on erasure scopes, this policy simply has
  # fewer ways in. The engines and the system actors never reach these actions
  # (`human_only`), so no bypass ahead of it covers them.
  policies do
    policy action([:view, :consent, :sign, :decline, :request_changes]) do
      description "Only the person a signer row names takes its acts."

      authorize_if {AshEnterprise.Signatures.Checks.SignerReach,
                    via: :signer, actions: [:view, :consent, :sign, :decline, :request_changes]}
    end
  end

  changes do
    change {AshEnterprise.Erasure.Changes.SealUnderScope,
            fields: AshSignatures.payload_fields(:signer)},
           on: [:create]

    # A signed acknowledgement of policy versions is a compliance event (CC1.1, CC2.2,
    # CC5.3), appended in the signing transaction. Acts only on `sign`.
    change AshEnterprise.Compliance.Changes.RecordPolicyAcknowledgement, on: [:update]

    # A reminder reaches the person: a message at their account's address, sent once the
    # `reminded` event has committed. The in-platform provider sends nothing itself.
    change AshEnterprise.Signatures.Changes.DeliverReminder,
      on: [:update],
      where: action_is(:remind)
  end

  attributes do
    attribute :user_id, :uuid do
      allow_nil? false
      public? true
      description "The person asked: a user of the organization."
    end
  end

  relationships do
    belongs_to :request, AshEnterprise.Signatures.Request do
      public? true
      define_attribute? false
    end

    belongs_to :user, AshEnterprise.Accounts.User do
      public? true
      define_attribute? false
    end

    belongs_to :erasure_scope, AshEnterprise.Erasure.Scope do
      public? true
      description "The person's own erasure scope, which `name` and `email` are sealed under."
    end
  end

  calculations do
    calculate :consent_given, :boolean, expr(not is_nil(consented_at)) do
      public? true
      description "Whether the person has agreed to acknowledge electronically."
    end

    calculate :policies_label,
              :string,
              {AshEnterprise.Signatures.Calculations.PolicyDocuments, kind: :titles} do
      public? true
      description "The documents the request names, by title and version."
    end

    calculate :documents_shown,
              :string,
              {AshEnterprise.Signatures.Calculations.PolicyDocuments, kind: :documents} do
      public? true

      description "What the person reads: each document's version, fingerprint and words. Shown once they open the request."
    end

    calculate :consent_wording, :string, AshEnterprise.Signatures.Calculations.ConsentWording do
      public? true
      description "What agreeing to acknowledge electronically means."
    end

    calculate :recorded?, :boolean, expr(erasure_scope.status == :active) do
      public? true

      description "False once the person's erasure scope is shredded: `name` and `email` then read as erased."
    end
  end

  identities do
    identity :unique_person, [:request_id, :user_id]
  end

  # ADR 0032: how these columns may leave production in a copy (greenmask.yml).
  greenmask do
    keep(:encrypted_name,
      because:
        "ciphertext sealed under an erasure-scope key; a copy's scope keys are replaced (Erasure.Key.wrapped_key), so it cannot be opened there"
    )

    keep(:encrypted_email,
      because:
        "ciphertext sealed under an erasure-scope key; a copy's scope keys are replaced (Erasure.Key.wrapped_key), so it cannot be opened there"
    )
  end
end
