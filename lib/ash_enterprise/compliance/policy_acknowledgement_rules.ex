defmodule AshEnterprise.Compliance.PolicyAcknowledgementRules do
  @moduledoc """
  The rules for the SOC 2 criteria the yearly policy review serves (the soc2 pack's
  `policy_review_acknowledgement`): CC1.1, CC2.2 and CC5.3.

  Subject: a user of the organization (`"person"` in the facts). One fact decides all
  three criteria, and the facts are computed by `AshEnterprise.Compliance.PolicyAcknowledgement`
  when the person acknowledges or when a policy is published:

    * `true`: the person holds a signed acknowledgement of the current version of every
      current policy. In.
    * `false`: they have acknowledged a policy here, but not the current version of every
      current one (a new version was published, or a new policy). Out.
    * absent: they have never acknowledged a policy here, or no policy is published.
      Unknown, never a pass.

  The three rules say the same thing under three criteria, because the finding grain is
  per control: each criterion gets its own finding row per person.

  Not part of the organization's compliance bundle, like `AshEnterprise.Mdm.QualityRules`:
  `AshEnterprise.Compliance.PolicyAcknowledgementProjector` bundles this module directly.
  `compile_policy_bundle!/1` folds every active revision of an organization into one bundle,
  and the KYC review appends one event per gap that bundle declares, so these criteria would
  then be evaluated against KYC facts.
  """

  use AshRules

  combining(:deny_overrides)

  fact_schema do
    fact(:acknowledged_current_policies, :boolean,
      missing: :unknown,
      description:
        "The person holds a signed acknowledgement of the current version of every current policy"
    )
  end

  rule "people acknowledge the current code of conduct and policies",
    id: "policy_ack.cc1_1",
    severity: :medium,
    message: "the current version of every current policy is not acknowledged" do
    fails_when(neg(:person, :acknowledged_current_policies, true))
    outcome(:noncompliant, gap: "CC1.1")
  end

  rule "people have received the policies that state their control duties",
    id: "policy_ack.cc2_2",
    severity: :medium,
    message: "the current version of every current policy is not acknowledged" do
    fails_when(neg(:person, :acknowledged_current_policies, true))
    outcome(:noncompliant, gap: "CC2.2")
  end

  rule "people acknowledge the policies and procedures in force",
    id: "policy_ack.cc5_3",
    severity: :medium,
    message: "the current version of every current policy is not acknowledged" do
    fails_when(neg(:person, :acknowledged_current_policies, true))
    outcome(:noncompliant, gap: "CC5.3")
  end
end
