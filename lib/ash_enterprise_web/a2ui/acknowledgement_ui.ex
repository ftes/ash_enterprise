defmodule AshEnterpriseWeb.A2ui.AcknowledgementUI do
  @moduledoc """
  Acknowledgements: the policies the signed-in person has been asked to read and
  acknowledge (ADR 0074, ADR 0070 section 5), one card per request.

  The person's own `Signer` rows are the list (`Signer.mine`); another person's request is
  neither listed nor reachable, and an automation principal reaches none of the acts.
  Choosing a card opens it beside the list: what the request asks them to read, each
  document's title and version, the SHA-256 of the bytes it names and where the original
  is served, with the words of a text policy inline. It takes four steps, each the
  signer's own act on their own row:

    1. **Open the documents** (`view`): records that they opened them, and shows them.
    2. **I agree** (`consent`): agrees to acknowledge electronically. Only after opening.
    3. **Acknowledge** (`sign`): records the acknowledgement, with the fingerprint of what
       they were shown. Refused without consent, by the package.
    4. **Decline** (`decline`): with a reason, from either of the first two steps.

  Every button runs the signer's own action as the clicking person; the signer's policy,
  one grant path on the row's `user_id`, decides (`AshEnterprise.Signatures.Signer`).
  `visible_when` only hides what is not offered. An acknowledgement of one version is kept
  when the next is published: a new request is opened, and this one stays as it was.

  Served at `/app/acknowledgements`. The documents' original bytes are served to the
  people a request names by `AshEnterpriseWeb.AcknowledgementDocumentController`.
  """

  use AshA2ui.Standalone

  a2ui do
    for_resource AshEnterprise.Signatures.Signer
    surface_id "acknowledgements"
    title "Acknowledgements"
    record_label "acknowledgement"

    context :request do
      resource AshEnterprise.Signatures.Signer
      picker false
    end

    component :table, :requests do
      fields [:policies_label, :status, :notified_at, :signed_at]
      read_action :mine
      row_actions [:view, :consent, :sign, :decline]
      select_context :request

      row_layout do
        title :policies_label
        meta [:status, :notified_at, :signed_at]
      end
    end

    component :detail, :request_detail do
      context :request

      fields [
        :policies_label,
        :status,
        :documents_shown,
        :consent_wording,
        :notified_at,
        :viewed_at,
        :consented_at,
        :signed_at,
        :shown_sha256
      ]
    end

    action :view do
      label "Open the documents"
      visible_when status: :notified
      refreshes [:requests]
    end

    action :consent do
      label "I agree"
      visible_when status: :viewed, consent_given: false
      refreshes [:requests]
    end

    action :sign do
      label "Acknowledge"
      visible_when status: :viewed, consent_given: true
      refreshes [:requests]
    end

    action :decline do
      label "Decline"
      visible_when status: [:notified, :viewed]
      prompt_fields [:reason]
      prompt_title "Decline: why you are not acknowledging"
      refreshes [:requests]
    end

    field :policies_label do
      label "Policies"
    end

    field :status do
      label "Where it stands"
    end

    field :notified_at do
      label "Asked on"
    end

    field :viewed_at do
      label "Opened on"
    end

    field :consented_at do
      label "Agreed on"
    end

    field :signed_at do
      label "Acknowledged on"
    end

    field :shown_sha256 do
      label "Fingerprint of what you were shown"
    end

    field :documents_shown do
      label "The documents"
    end

    field :consent_wording do
      label "What you agree to"
    end
  end
end
