defmodule AshEnterprise.Compliance.Policy do
  @moduledoc """
  One published version of one organisation policy, and which version is current.

  A policy is a document the organisation asks its people to read and acknowledge. The
  bytes are an `AshEvidence.DocumentVersion` (`document_version_id`): the evidence store
  holds the content, addressed by its SHA-256, and keeps it untouched. This row says which
  policy the document is, which version of it, and whether it is the current one. It is a
  host resource rather than a kind on `DocumentVersion` because that is a package
  resource with no update action, no title and no version, and it is unique by hash.

  ## The rules

    * A policy is named by its `policy_key` (`"acceptable-use"`). Each `publish` of a key
      mints version 1, 2, 3 and so on.
    * At most one row per key is current (`superseded_at` is nil). A partial unique index
      holds that, so two publishes racing cannot both win.
    * Publishing the bytes that are already current for the key mints nothing: the current
      row comes back as it was. Bytes seen before under an older version are a new
      version, because the current policy is not that text.
    * Publishing supersedes the previous current row and mints the next one in one
      transaction. When the new row cannot be written, the old one is still current.
    * A superseded row is never edited again and never deleted: a person who acknowledged
      version 1 keeps that acknowledgement, and version 1 stays readable.

  `sha256` is the lowercase hex SHA-256 of the bytes, as `AshEvidence.DocumentVersion`
  records it. Anyone who needs to say what a person was shown names the policy version,
  not a copy of its hash.

  ## Authority

  Publishing changes what everyone in the organisation is asked to acknowledge, so
  `publish` and the two writes under it are `human_only`: an automation principal never
  reaches them. The grants decide who may publish and who may read.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Compliance,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    human_only: [:publish, :mint, :supersede]

  alias AshEnterprise.Compliance.Policy.Actions

  postgres do
    table "compliance_policies"
    repo AshEnterprise.Repo

    identity_wheres_to_sql one_current_per_key: "superseded_at IS NULL"
  end

  attributes do
    uuid_primary_key :id

    attribute :policy_key, :string do
      allow_nil? false
      public? true
      constraints max_length: 100, match: ~r/\A[a-z0-9][a-z0-9._-]*\z/
      description "The policy's stable name, lowercase: `acceptable-use`."
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints max_length: 200
    end

    attribute :version, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :document_version_id, :uuid do
      allow_nil? false
      public? true
      description "The bytes, in the evidence store (`AshEvidence.DocumentVersion`)."
    end

    attribute :sha256, :string do
      allow_nil? false
      public? true
      description "Lowercase hex SHA-256 of the bytes."
    end

    attribute :published_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :superseded_at, :utc_datetime_usec do
      public? true
      description "When a later version replaced this one. Nil while it is current."
    end
  end

  identities do
    identity :one_version_per_key, [:policy_key, :version]
    identity :one_current_per_key, [:policy_key], where: expr(is_nil(superseded_at))
  end

  actions do
    defaults [:read]

    read :current do
      description "The policies in force: one row per key, the current version."
      filter expr(is_nil(superseded_at))
      prepare build(sort: [policy_key: :asc])
    end

    read :versions_of do
      description "Every version of one policy, newest first."

      argument :policy_key, :string, allow_nil?: false, public?: true

      filter expr(policy_key == ^arg(:policy_key))
      prepare build(sort: [version: :desc])
    end

    action :publish, :struct do
      description """
      Publish a policy. Ingests the bytes, supersedes the key's current version and mints
      the next one, in one transaction. The bytes that are already current mint nothing and
      the current row is returned.
      """

      constraints instance_of: __MODULE__
      transaction? true

      argument :policy_key, :string do
        allow_nil? false
        public? true
        constraints max_length: 100, match: ~r/\A[a-z0-9][a-z0-9._-]*\z/
      end

      # Checked where it is stored (`:mint`), after the bytes are ingested and the old
      # version superseded, so a refusal rolls all of that back.
      argument :title, :string do
        allow_nil? false
        public? true
        constraints allow_empty?: true, trim?: false
      end

      argument :content, :binary, allow_nil?: false, public?: true

      run Actions.Publish
    end

    create :mint do
      description "Write the next version of a policy. Called by `:publish`."
      accept [:policy_key, :title, :version, :document_version_id, :sha256]
      change set_attribute(:published_at, &DateTime.utc_now/0)

      # The people in scope are evaluated again for the policy criteria: a new version
      # puts out whoever held only the old one (`Compliance.PolicyAcknowledgement`).
      change AshEnterprise.Compliance.Changes.ReviewPolicyAcknowledgements
    end

    update :supersede do
      description "Close a current version. Called by `:publish`."
      accept []
      change set_attribute(:superseded_at, &DateTime.utc_now/0)
    end
  end
end
