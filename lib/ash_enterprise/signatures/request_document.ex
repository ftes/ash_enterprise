defmodule AshEnterprise.Signatures.RequestDocument do
  @moduledoc """
  One document a signature request shows: the `AshSignatures.RequestDocument` fragment on
  the platform base, in table `signature_request_documents`.

  The version is an `AshEvidence.DocumentVersion`, held by id with no foreign key (the
  evidence store has a repo of its own), and its SHA-256 is copied onto this row when the
  document is added, so neither the request's digest nor its completion record reads the
  version again.

  Organization-owned and append-only in practice: `add` (on a draft request) goes through
  the grant union, and `record_result`, the package's write of a signed copy, is
  machinery-only. A signer reads the documents of the requests they are asked on
  (`AshEnterprise.Signatures.Checks.SignerReach`).
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Signatures,
    ownership: :organization_owned,
    lifecycle?: false,
    archival?: false,
    machinery_only: [:record_result],
    extra_grants: [{AshEnterprise.Signatures.Checks.SignerReach, via: :request_document}],
    fragments: [AshSignatures.RequestDocument]

  postgres do
    table "signature_request_documents"
    repo AshEnterprise.Repo

    references do
      reference :request, on_delete: :restrict
    end
  end

  signatures do
    request AshEnterprise.Signatures.Request
  end

  relationships do
    belongs_to :request, AshEnterprise.Signatures.Request do
      public? true
      define_attribute? false
    end
  end
end
