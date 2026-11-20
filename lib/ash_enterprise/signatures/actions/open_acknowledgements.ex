defmodule AshEnterprise.Signatures.Actions.OpenAcknowledgements do
  @moduledoc """
  Runs `AshEnterprise.Signatures.Request.open_acknowledgements`: when the year's policy
  review falls due, every person in scope is asked to acknowledge the current policies.

  The first step of the `soc2` pack's policy review (`priv/packs/soc2/`), named by its
  service task (`policy_acknowledgements_open` in `AshEnterprise.Process.ActionInvoker`).
  Under the recipe's standing grant it runs as the recipe runner acting for the person who
  published the recipe, and every read and write below is authorized as that caller.

  ## What it does

    1. Reads the occurrence as the caller, so another organization's is not found. Anything
       but a `compliance.review_due` occurrence for `policy_review_acknowledgement` is
       refused with the business error `not_a_policy_review`.
    2. Reads the current policies (`AshEnterprise.Compliance.Policy.current`), one version
       per key, in key order.
    3. Reads the people in scope (`AshEnterprise.Accounts.User.asked_to_acknowledge`: every
       active user whose home business unit is in the organization). Which people the
       organization has is the action's bookkeeping, read without authorization, the way a
       signer row reads the person it names; what is written for each is authorized as the
       caller.
    4. For each person, in its own transaction: a person this review has already asked over
       exactly the current versions is left alone, whatever became of that request (a
       replay opens nothing). Otherwise the person's open acknowledgement requests are
       cancelled, and one request is drafted (`draft_acknowledgement`, the person as its
       subject, this occurrence as its review), given one document per current version in
       key order, the person as its only signer (`add_person`), and sent in the app. The
       person's standing is recorded for the policy criteria in the same transaction
       (`AshEnterprise.Compliance.PolicyAcknowledgement.record_entered/4`), so everyone
       asked has a finding, unknown until they acknowledge.

  ## A person who has been erased

  Erasing a person shreds their own erasure scope and leaves their account as it was, so
  they can still be an active user of the organization. A signer row is sealed under that
  scope, and nothing new may land under a shredded one, so such a person cannot be asked.
  They are skipped and counted (`"erased"`), and everyone else is still asked: one person
  who cannot be asked never stops the review for the people after them.

  One request per person, not one request with everyone on it: the package moves signers in
  order and reminds only the signer whose turn it is, so a request per person is what lets
  everyone acknowledge at once and be reminded on their own.

  A policy published after the review opened is a different set of versions: running this
  again for the same review asks each person over the new set, and keeps what they
  acknowledged before.

  Answers `%{"policies" => p, "people" => n, "opened" => o, "already_asked" => a,
  "cancelled" => c, "erased" => e}`. With no current policy there is nothing to acknowledge and nothing is
  opened.
  """

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias AshAgent.BusinessError
  alias AshEnterprise.Accounts.User
  alias AshEnterprise.Automation.{Occurrence, Occurrences}
  alias AshEnterprise.Compliance
  alias AshEnterprise.Compliance.PolicyAcknowledgement
  alias AshEnterprise.Erasure
  alias AshEnterprise.Execution.Changes.SealingScope
  alias AshEnterprise.Signatures
  alias AshEnterprise.Signatures.Request

  @template "policy_review_acknowledgement"
  @open [:draft, :sent, :partially_signed]

  @impl true
  def run(input, _opts, context) do
    opts = Ash.Context.to_opts(context)

    with {:ok, occurrence} <- policy_review(input.arguments.id, opts),
         {:ok, policies} <- Compliance.current_policies(opts),
         {:ok, people} <- people(occurrence.organization_id),
         {:ok, tally} <- ask_all(people, occurrence, policies, opts) do
      {:ok,
       %{
         "policies" => length(policies),
         "people" => length(people),
         "opened" => tally.opened,
         "already_asked" => tally.already_asked,
         "cancelled" => tally.cancelled,
         "erased" => tally.erased
       }}
    end
  end

  @none %{opened: 0, already_asked: 0, cancelled: 0, erased: 0}

  # No current policy: nothing to acknowledge, so nobody is asked.
  defp ask_all(_people, _occurrence, [], _opts), do: {:ok, @none}

  defp ask_all(people, occurrence, policies, opts) do
    Enum.reduce_while(people, {:ok, @none}, fn person, {:ok, tally} ->
      case ask(person, occurrence, policies, opts) do
        {:ok, outcome} -> {:cont, {:ok, count(tally, outcome)}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp count(tally, :already_asked), do: Map.update!(tally, :already_asked, &(&1 + 1))
  defp count(tally, :erased), do: Map.update!(tally, :erased, &(&1 + 1))

  defp count(tally, {:opened, cancelled}),
    do: %{tally | opened: tally.opened + 1, cancelled: tally.cancelled + cancelled}

  @doc false
  def policy_review(id, opts) do
    case Ash.get(Occurrence, id, Keyword.put(opts, :not_found_error?, false)) do
      {:ok, %Occurrence{} = occurrence} ->
        if policy_review?(occurrence),
          do: {:ok, occurrence},
          else: refuse("not_a_policy_review")

      {:ok, nil} ->
        refuse("not_a_policy_review")

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "Whether `occurrence` is the policy review falling due."
  @spec policy_review?(map()) :: boolean()
  def policy_review?(%{type: type, data: %{"template" => @template}}),
    do: type == Occurrences.review_due()

  def policy_review?(_occurrence), do: false

  defp people(organization_id) do
    User
    |> Ash.Query.for_read(:asked_to_acknowledge, %{organization_id: organization_id})
    |> Ash.Query.select([:id, :email])
    |> Ash.read(authorize?: false)
  end

  # One person, in one transaction: a failure leaves nothing half-written for them, and the
  # people before them keep their requests.
  defp ask(person, occurrence, policies, opts) do
    hashes = policies |> Enum.map(& &1.sha256) |> Enum.sort()

    with {:ok, false} <- erased?(person.id),
         {:ok, theirs} <- requests_of(person.id, opts) do
      ask(person, occurrence, policies, theirs, hashes, opts)
    else
      {:ok, true} -> {:ok, :erased}
      {:error, error} -> {:error, error}
    end
  end

  # The person's own erasure scope (the one their signer row would be sealed under) has
  # been shredded. Bookkeeping, like reading who the people are: read without
  # authorization. A person never yet asked has no scope, and is not erased.
  defp erased?(user_id) do
    case Erasure.scope_by_ref(:data_subject, SealingScope.scope_ref(user_id), authorize?: false) do
      {:ok, %{status: :shredded}} -> {:ok, true}
      {:ok, _active_or_none} -> {:ok, false}
      {:error, error} -> {:error, error}
    end
  end

  defp ask(person, occurrence, policies, theirs, hashes, opts) do
    if Enum.any?(theirs, &(&1.occurrence_id == occurrence.id and hashes(&1) == hashes)) do
      {:ok, :already_asked}
    else
      stale = Enum.filter(theirs, &(&1.status in @open))
      transaction(fn -> open(person, occurrence, policies, stale, opts) end)
    end
  end

  defp requests_of(user_id, opts) do
    subject_id = to_string(user_id)
    subject_type = Request.acknowledgement()

    Request
    |> Ash.Query.filter(subject_type == ^subject_type and subject_id == ^subject_id)
    |> Ash.Query.load(:documents)
    |> Ash.read(opts)
  end

  defp hashes(request), do: request.documents |> Enum.map(& &1.source_sha256) |> Enum.sort()

  defp open(person, occurrence, policies, stale, opts) do
    Enum.each(stale, &Signatures.cancel_signature_request!(&1, opts))

    request =
      Signatures.draft_acknowledgement!(
        %{occurrence_id: occurrence.id, user_id: person.id},
        opts
      )

    policies
    |> Enum.with_index(1)
    |> Enum.each(fn {policy, position} ->
      Signatures.add_signature_document!(
        %{
          request_id: request.id,
          source_version_id: policy.document_version_id,
          position: position
        },
        opts
      )
    end)

    Signatures.add_signer!(
      %{request_id: request.id, role: :acknowledger, order: 1, user_id: person.id},
      opts
    )

    Signatures.send_signature_request!(request, opts)

    :ok =
      PolicyAcknowledgement.record_entered(occurrence.organization_id, person.id, "asked")

    {:opened, length(stale)}
  end

  defp transaction(fun) do
    AshEnterprise.Repo.transaction(fn ->
      try do
        fun.()
      rescue
        error -> AshEnterprise.Repo.rollback(error)
      end
    end)
  end

  defp refuse(code), do: {:error, BusinessError.exception(code: code)}
end
