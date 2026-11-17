defmodule AshEnterprise.Audit.ExportCursor do
  @moduledoc """
  How far the audit export (`AshEnterprise.Audit.ExportWorker`) has shipped one audit chain
  to the deployment's OTLP log endpoint.

  One row per chain, the chain with no tenant included, so `chain_organization_id` is
  nullable and the resource is not tenant-scoped (the same shape as
  `AshEnterprise.Audit.ArchiveRun`). `last_sequence` is the last event the endpoint
  acknowledged with a 2xx; the next run reads after it. `exported_count` counts the events
  acknowledged. While a chain's exports fail, `failing_since` says since when and
  `last_error` says why in a few words (an HTTP status or a transport reason): never a
  payload, a header or an endpoint's credentials.

  Bookkeeping, not a record, so it opts out the way `AshEnterprise.Bpmn.Cursor` does:
  `ownership: :none`, no lifecycle, no soft delete, and **not audited**. Auditing it would
  write an event into the very log it drains on every advance, so each export would make
  the next one.

  Machinery-only writes (ADR 0059): `start`, `advance` and `fail` are run by the `oban`
  system actor alone. Reading follows the grant union.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Audit,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    machinery_only: [:start, :advance, :fail]

  @error_length 200

  postgres do
    table "audit_export_cursors"
    repo AshEnterprise.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :chain_organization_id, :uuid do
      public? true
      description "The chain's tenant; nil for the chain of events written outside any tenant."
    end

    attribute :last_sequence, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
      description "The last event the endpoint acknowledged; the next run exports after it."
    end

    attribute :exported_count, :integer do
      allow_nil? false
      default 0
      public? true
      constraints min: 0
      description "Events of this chain the endpoint has acknowledged."
    end

    attribute :last_exported_at, :utc_datetime_usec do
      public? true
      description "When the endpoint last acknowledged a batch of this chain."
    end

    attribute :failing_since, :utc_datetime_usec do
      public? true
      description "The first failed export since the last success; nil while exports succeed."
    end

    attribute :last_error, :string do
      public? true
      constraints max_length: @error_length

      description "Why the last export failed, in a few words: an HTTP status or a transport reason."
    end
  end

  identities do
    # One cursor per chain, the NULL chain included: NULLS NOT DISTINCT, so a second
    # cursor for the chain with no tenant collides like any other.
    identity :one_per_chain, [:chain_organization_id], nils_distinct?: false
  end

  actions do
    defaults [:read]

    read :for_chain do
      description "The cursor of one chain, or nothing before its first export."
      get? true

      argument :organization_id, :uuid, allow_nil?: true

      filter expr(
               if is_nil(^arg(:organization_id)) do
                 is_nil(chain_organization_id)
               else
                 chain_organization_id == ^arg(:organization_id)
               end
             )
    end

    create :start do
      description "A chain's cursor, before its first export: everything still hot is after it."
      accept [:chain_organization_id]
    end

    update :advance do
      description """
      The endpoint acknowledged a batch: move past its last event and clear any failure.
      """

      accept []

      argument :last_sequence, :integer, allow_nil?: false, constraints: [min: 0]
      argument :exported, :integer, allow_nil?: false, constraints: [min: 0]

      change set_attribute(:last_sequence, arg(:last_sequence))
      change atomic_update(:exported_count, expr(exported_count + ^arg(:exported)))
      change set_attribute(:last_exported_at, &DateTime.utc_now/0)
      change set_attribute(:failing_since, nil)
      change set_attribute(:last_error, nil)
    end

    update :fail do
      description "An export of this chain failed: the cursor stays, and the failure is kept."

      accept []

      argument :reason, :string, allow_nil?: false, constraints: [max_length: @error_length]

      change set_attribute(:last_error, arg(:reason))

      change atomic_update(
               :failing_since,
               expr(if is_nil(failing_since), do: now(), else: failing_since)
             )
    end
  end
end
