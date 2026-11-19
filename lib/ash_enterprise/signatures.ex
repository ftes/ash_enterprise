defmodule AshEnterprise.Signatures do
  @moduledoc """
  Signature and acknowledgement requests (ADR 0074): the five `ash_signatures` fragments on
  the platform base.

    * `AshEnterprise.Signatures.Request`: people asked to sign or acknowledge exact document
      versions, in order.
    * `AshEnterprise.Signatures.RequestDocument`: one document version a request shows, with
      the SHA-256 copied from it.
    * `AshEnterprise.Signatures.Signer`: one person asked, acting on their own row.
    * `AshEnterprise.Signatures.SignerEvent`: one thing that happened, append-only.
    * `AshEnterprise.Signatures.Completion`: the canonical record a completed request ends in,
      append-only.

  The package declares the attributes, actions, changes and state machines. This domain
  supplies the rest: tenancy and ownership, who may act (a signer is a user of the
  organization, and only that person views, consents, signs or declines on their row),
  sealing of the signer's personal fields under the person's own erasure scope, the audit
  chain head written into each completion (`AshEnterprise.Signatures.ChainHead`) and the
  effects declarations of the writes a host process makes. Document versions are
  `AshEvidence.DocumentVersion` rows.
  """

  use Ash.Domain,
    otp_app: :ash_enterprise,
    extensions: [AshAgent.Effects.Domain]

  resources do
    resource AshEnterprise.Signatures.Request do
      define :draft_signature_request, action: :draft
      define :send_signature_request, action: :send
      define :recall_signature_request, action: :recall
      define :cancel_signature_request, action: :cancel
      define :expire_signature_request, action: :expire
      define :get_signature_request, action: :read, get_by: [:id]
      define :list_signature_requests, action: :read
    end

    resource AshEnterprise.Signatures.RequestDocument do
      define :add_signature_document, action: :add
      define :list_signature_documents, action: :read
    end

    resource AshEnterprise.Signatures.Signer do
      define :add_signer, action: :add_person
      define :get_signer, action: :read, get_by: [:id]
      define :list_signers, action: :read
      define :view_signature_request, action: :view
      define :consent_to_sign, action: :consent
      define :sign_signature_request, action: :sign
      define :decline_signature_request, action: :decline, args: [:reason]
      define :request_signature_changes, action: :request_changes, args: [:reason]
      define :remind_signer, action: :remind
    end

    resource AshEnterprise.Signatures.SignerEvent do
      define :list_signer_events, action: :read
    end

    resource AshEnterprise.Signatures.Completion do
      define :list_signature_completions, action: :read
    end
  end
end
