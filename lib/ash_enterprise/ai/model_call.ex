defmodule AshEnterprise.AI.ModelCall do
  @moduledoc """
  One model call: the ADR 0042 flow record.

  Written by `AshEnterprise.AI.Models` for every call that passes through it —
  made, failed, or refused by the in-zone guard — so "which model saw what
  kind of request, from where, and was it inside the zone" is answerable from
  data rather than from logs.

  **Structural only.** Caller, organisation, profile, model, residency, zone,
  operation, outcome, correlation id, duration and token counts. Never a
  prompt, an output, a tool argument or an error message (which can echo
  either): a failure, or a refusal, is recorded by its error *class*. The
  correlation id joins a call to the audited action that made it
  (`AshEnterprise.Audit.EventLog`).

  ## Whose call it was

  `organization_id` is the tenant the call was made for, as the caller named
  it to the guard (`tenant:`), and nil for a call made for no tenant (a
  declared tenantless caller, or one the guard refused for naming none).
  `:disclosures` is a tenant's own answer to "what did a model outside our
  zone see": the outside-zone calls made, failed or refused for the tenant
  the read runs in, and nothing for a read with no tenant.

  ## Append-only

  One create action, no update, no destroy: a row is never changed or
  removed. Deliberate opt-outs, each because of that:

    * `audit?: false` — this *is* an append-only log; mirroring every row into
      the event log would double each call and add nothing a reader of either
      could use. The audited action that made the call carries the same
      correlation id.
    * `archival?: false` — nothing is ever deleted, softly or otherwise.
    * `ownership: :none`, `tenant?: false`, `lifecycle?: false` — operational
      bookkeeping like the sync cursors, written by the `system` actor.
      Reads go through the inherited grant union like any other resource.
      `tenant?: false` because a call can be made for no tenant, which the
      platform's tenant attribute (never nil) cannot hold; `organization_id`
      is a plain attribute instead, and `:disclosures` narrows by it.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.AI,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false

  postgres do
    table "ai_model_calls"
    repo AshEnterprise.Repo

    custom_indexes do
      index [:created_on]
      index [:correlation_id]
      index [:organization_id, :residency]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :caller, :string do
      allow_nil? false
      public? true
      constraints max_length: 120
      description "What made the call, e.g. \"ai.interpret_request\"."
    end

    attribute :organization_id, :uuid do
      public? true

      description "The tenant the call was made for; nil when the caller named none."
    end

    attribute :profile, :string do
      allow_nil? false
      public? true
      constraints max_length: 60

      description ~s("in_zone_generative" for the operator's in-zone profile; "hosted" for anything else.)
    end

    attribute :model, :string do
      allow_nil? false
      public? true
      constraints max_length: 200
      description "The model, as provider:id."
    end

    attribute :residency, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:in_zone, :outside_zone]
    end

    attribute :zone, :string do
      public? true
      constraints max_length: 120
      description "The declared zone of an in-zone profile; nil outside every zone."
    end

    attribute :operation, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:generate_object, :generate_text, :stream_text]
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ok, :error, :refused]

      description ":refused means the guard stopped the call before anything was sent: " <>
                    "outside the zone with no recorded opt-in, or under REQUIRE_IN_ZONE_MODELS."
    end

    attribute :correlation_id, :string do
      public? true
      constraints max_length: 64
    end

    attribute :input_tokens, :integer, public?: true, constraints: [min: 0]
    attribute :output_tokens, :integer, public?: true, constraints: [min: 0]
    attribute :duration_ms, :integer, public?: true, constraints: [min: 0]

    attribute :error_class, :string do
      public? true
      constraints max_length: 200
      description "The failure's exception module. Never its message."
    end
  end

  actions do
    defaults [:read]

    read :disclosures do
      description """
      The calls to a model outside the zone made, failed or refused for the
      tenant this read runs in: what a model sub-processor was sent, or asked
      to be sent, on the tenant's behalf. Nothing when the read has no tenant.
      """

      filter expr(residency == :outside_zone)
      prepare AshEnterprise.AI.ModelCall.Preparations.ForTenant
    end

    create :record do
      description "Append one call record. There is no update and no destroy."

      accept [
        :caller,
        :organization_id,
        :profile,
        :model,
        :residency,
        :zone,
        :operation,
        :outcome,
        :correlation_id,
        :input_tokens,
        :output_tokens,
        :duration_ms,
        :error_class
      ]
    end
  end

  code_interface do
    define :record
    define :disclosures
  end
end
