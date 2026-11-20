defmodule AshEnterprise.Signatures.Changes.DeliverReminder do
  @moduledoc """
  On a signer's `remind`: once the reminder has committed, the person is sent the reminder
  message (`AshEnterprise.Signatures.Senders.SendReminder`) at their account's address.

  The package's in-platform provider records the `reminded` event and sends nothing: the
  message is the host's (`AshSignatures.Providers.InPlatform`). After the transaction, not
  inside it, so a reminder that rolls back sends nothing and a message that cannot be sent
  never undoes the reminder; a failure is logged. Nothing is sent to a person who is no
  longer an active user, or whose erasure scope has been shredded.

  The account is read without authorization: which address the person has is the
  bookkeeping of a reminder the job runner was authorized to send.
  """

  use Ash.Resource.Change

  require Ash.Query
  require Logger

  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Signatures.Senders.SendReminder

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn
      _changeset, {:ok, signer} = result ->
        deliver(signer)
        result

      _changeset, result ->
        result
    end)
  end

  defp deliver(signer) do
    with %User{lifecycle_status: :active, email: email} <- user(signer.user_id),
         true <- recorded?(signer),
         {:ok, _sent} <- SendReminder.deliver(to_string(email)) do
      :ok
    else
      # The error is not logged: a mail adapter's error can carry the address.
      {:error, _error} ->
        Logger.warning("signature reminder message for signer #{signer.id} not sent")

      _not_sent ->
        :ok
    end
  end

  defp user(user_id) do
    User
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp recorded?(signer) do
    signer
    |> Ash.load!(:recorded?, authorize?: false, tenant: signer.organization_id)
    |> Map.fetch!(:recorded?)
  end
end
