defmodule AshEnterprise.Signatures.Calculations.ConsentWording do
  @moduledoc """
  The words a person agrees to before they acknowledge, in the locale they read the
  surface in. The same text is shown on every request; what they agree to is recorded as
  the `consented` event, with the time, and the `signed` event records the SHA-256 of what
  they were shown.
  """

  use Ash.Resource.Calculation
  use Gettext, backend: AshEnterpriseWeb.Gettext

  @impl true
  def calculate(records, _opts, _context) do
    wording =
      dgettext(
        "default",
        "By choosing \"I agree\" you agree to acknowledge these documents electronically. " <>
          "Acknowledging records that you read this version, with the time and a fingerprint (SHA-256) of the text you were shown."
      )

    Enum.map(records, fn _signer -> wording end)
  end
end
