defmodule AshEnterprise.Signatures.Senders.SendReminder do
  @moduledoc """
  The reminder message: a person a signature or acknowledgement request is waiting on is
  sent a short message at their account's address, with a link to the page where they act
  on it (`/app/acknowledgements`).

  The message names no document, policy, organization or other person: it says that
  something is waiting and where to find it, and the person reads the rest after signing
  in. The address is the account's own, read when the reminder is sent, not the address
  sealed on the signer row.

  Sent by `AshEnterprise.Signatures.Changes.DeliverReminder` once the signer's `remind`
  has committed. Listed with the other account mail in `AshEnterprise.Governance.DataFlows`.
  """

  use AshEnterpriseWeb, :verified_routes

  import Swoosh.Email

  alias AshEnterprise.Mailer

  @subject "A request is waiting for you"

  @doc "The message's subject line."
  @spec subject() :: String.t()
  def subject, do: @subject

  @doc "Sends the reminder to `address`."
  @spec deliver(String.t()) :: {:ok, term()} | {:error, term()}
  def deliver(address) when is_binary(address) do
    link = url(~p"/app/acknowledgements")

    new()
    # The same literal sender as the account mail (`SendPasswordResetEmail`): a deployment
    # sets the real address with the rest of the mailer configuration.
    |> from({AshEnterprise.Brand.product_name(), "noreply@example.com"})
    |> to(address)
    |> subject(@subject)
    |> text_body("""
    A request is waiting for you to read and acknowledge or sign.

    Open it here: #{link}
    """)
    |> html_body("""
    <p>A request is waiting for you to read and acknowledge or sign.</p>
    <p><a href="#{link}">Open it here</a></p>
    """)
    |> Mailer.deliver()
  end
end
