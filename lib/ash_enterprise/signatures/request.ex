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

  ## Policy acknowledgements

  When the policy review falls due, `open_acknowledgements` (the first step of the `soc2`
  pack's policy review, run as a governed target) asks each person in scope to acknowledge
  the current policies: one request per person (`draft_acknowledgement`: the person is the
  subject, the review's occurrence is `occurrence_id`), over one document per current
  policy version, sent in the app. `AshEnterprise.Signatures.Actions.OpenAcknowledgements`
  says what it does on a replay, after a new version, and in the next period.
  `review_status` says who has and has not acknowledged for one review
  (`AshEnterprise.Signatures.ReviewStatus`); the administrator's review task shows it.
  `AshEnterprise.Signatures.ReminderWorker` reminds the people still waiting.
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

    # A review's requests, and one person's acknowledgements, are each read together.
    custom_indexes do
      index [:occurrence_id]
      index [:subject_type, :subject_id]
    end
  end

  @acknowledgement "compliance.policy_acknowledgement"

  @doc """
  The `subject_type` of a policy acknowledgement: the subject is the person asked
  (`subject_id`, their user id). A completed acknowledgement supersedes the person's other
  open ones and nobody else's.
  """
  @spec acknowledgement() :: String.t()
  def acknowledgement, do: @acknowledgement

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

    action :open_acknowledgements,
      kind: :edit,
      read_only?: false,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      approval: :none,
      intent: :execute
  end

  attributes do
    attribute :occurrence_id, :uuid do
      public? true

      description "The scheduled review (an `AshEnterprise.Automation.Occurrence`) that " <>
                    "opened this request, when one did."
    end
  end

  actions do
    create :draft_acknowledgement do
      description """
      A draft request for one person to acknowledge the organization's policies, opened by
      the review `occurrence_id` names. The person is the subject; written by
      `open_acknowledgements`.
      """

      accept [:occurrence_id]

      argument :user_id, :uuid, allow_nil?: false, public?: true

      change set_attribute(:subject_type, @acknowledgement)
      change set_attribute(:subject_id, arg(:user_id))
      change set_attribute(:purpose, :acknowledge)
    end

    action :open_acknowledgements, :map do
      description """
      Asks every person in scope to acknowledge the current policies, for the policy review
      the occurrence `id` names: one request per person, over every current policy version,
      sent in the app. Idempotent per review: a person already asked by this review over the
      same versions is not asked again. A person's open acknowledgement requests from before
      are cancelled, so each person has one open request. Refuses an occurrence that is not a
      policy review falling due with `not_a_policy_review`.
      """

      argument :id, :uuid do
        allow_nil? false
        description "The `compliance.review_due` occurrence of the policy review."
      end

      run AshEnterprise.Signatures.Actions.OpenAcknowledgements
    end

    action :review_status, :map do
      description """
      Who has and has not acknowledged, for the policy review the occurrence `occurrence_id`
      names: each person asked, the newest request this review sent them, and where it
      stands. Read as the caller.
      """

      argument :occurrence_id, :uuid, allow_nil?: false, public?: true

      run AshEnterprise.Signatures.Actions.ReviewStatus
    end
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
