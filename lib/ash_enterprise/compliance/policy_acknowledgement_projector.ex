defmodule AshEnterprise.Compliance.PolicyAcknowledgementProjector do
  @moduledoc """
  The policy acknowledgement finding projector (ADR 0035): folds `policy_acknowledged` and
  `policy_published` events (`AshEnterprise.Compliance.PolicyAcknowledgement`) into
  findings on the grain `[organization_id, control_id, subject_type, subject_id]`, one row
  per person and criterion (CC1.1, CC2.2, CC5.3).

  The bundle is `AshEnterprise.Compliance.PolicyAcknowledgementRules` directly, never the
  organization's compliance bundle, whose fact schema is KYC's. The same shape as
  `AshEnterprise.Mdm.QualityProjector`: an organization with no compliance program seeded
  still projects, because the rules are code.
  """

  use AshCompliance.Projector,
    name: "policy_acknowledgement_findings_v1",
    event_log: AshEnterprise.Compliance.EventLog,
    projection_resource: AshCompliance.Resources.Finding,
    bundle: {__MODULE__, :active_bundle, []}

  grain(fn event ->
    metadata = event.metadata || %{}

    %{
      organization_id: metadata["organization_id"],
      control_id: metadata["control_id"],
      subject_type: metadata["subject_type"],
      subject_id: metadata["subject_id"]
    }
  end)

  project_all([:policy_acknowledged, :policy_published])

  @doc "The rules bundle, round-tripped through the IR like every seeded bundle. No lookup."
  def active_bundle(_event) do
    AshRules.Ir.decode(
      AshRules.Ir.encode!(AshEnterprise.Compliance.PolicyAcknowledgementRules.__bundle__())
    )
  end
end
