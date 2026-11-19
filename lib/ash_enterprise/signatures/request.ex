defmodule AshEnterprise.Signatures.Request do
  @moduledoc """
  A signature or acknowledgement request (ADR 0074): the `AshSignatures.Request` fragment
  on the platform base, in table `signature_requests`.

  ## What the fragment brings

  The subject, purpose (`:execute` or `:acknowledge`), routing, provider, documents digest
  and expiry; the state machine `draft → sent → partially_signed → completed`, ending
  otherwise in `returned`, `recalled`, `cancelled`, `expired` or `superseded`; and the
  actions. See `AshSignatures.Request`.

  ## What this resource adds

    * **Tenancy and ownership.** Tenant-scoped and organization-owned: the organization
      asks, so the people who manage requests reach them through a global grant. The
      fragment's state machine, not the base lifecycle (`lifecycle?: false`), and no soft
      delete (`archival?: false`): a request ends in a state, never by being removed.
    * **One provider.** Requests are signed in the app (`in_platform`). The upload provider
      is not offered.
    * **Who may do what.** `draft`, `send`, `recall` and `cancel` go through the grant
      union. `expire` is the job runner's (machinery-only). The package's own consequences
      of an act (`advance`, `return`, `supersede`, `receive_signed_copy`) are written with
      `authorize?: false` by the act a person was authorized for, and are machinery-only so
      no grant can call them directly. A signer reads the requests they are asked on
      (`AshEnterprise.Signatures.Checks.SignerReach`).
    * **Effects.** `send` is declared (`kind: :edit`, `open_world?: false`, no approval):
      a host process that opens requests runs it as a governed target.
    * **The chain head.** Each completion records the tenant's audit chain head
      (`AshEnterprise.Signatures.ChainHead`).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Signatures,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    machinery_only: [:expire, :advance, :return, :supersede, :receive_signed_copy],
    extra_grants: [{AshEnterprise.Signatures.Checks.SignerReach, via: :request}],
    extra_extensions: [AshAgent.Effects],
    fragments: [AshSignatures.Request]

  postgres do
    table "signature_requests"
    repo AshEnterprise.Repo
  end

  signature_request do
    request_document(AshEnterprise.Signatures.RequestDocument)
    signer(AshEnterprise.Signatures.Signer)
    signer_event(AshEnterprise.Signatures.SignerEvent)
    completion(AshEnterprise.Signatures.Completion)
    document_version(AshEvidence.DocumentVersion)
    chain_head(AshEnterprise.Signatures.ChainHead)
    providers(in_platform: AshSignatures.Providers.InPlatform)
  end

  effects do
    action :send,
      kind: :edit,
      read_only?: false,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      approval: :none,
      intent: :execute
  end

  relationships do
    has_many :documents, AshEnterprise.Signatures.RequestDocument do
      public? true
      destination_attribute :request_id
      sort position: :asc
    end

    has_many :signers, AshEnterprise.Signatures.Signer do
      public? true
      destination_attribute :request_id
      sort order: :asc
    end

    has_many :events, AshEnterprise.Signatures.SignerEvent do
      public? true
      destination_attribute :request_id
    end

    has_one :completion, AshEnterprise.Signatures.Completion do
      public? true
      destination_attribute :request_id
    end
  end
end
