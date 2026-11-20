defmodule AshEnterprise.Signatures.ReaskWorker do
  @moduledoc """
  Asks everyone again when a new policy version is published: runs the organization's
  policy review fan-out (`AshEnterprise.Signatures.Request.open_acknowledgements`) on its
  latest policy review, so each person is asked over the new set of current versions in
  the same review, and their earlier acknowledgements are kept.

  Enqueued by the policy's `mint` (`AshEnterprise.Compliance.Changes.ReviewPolicyAcknowledgements`),
  inside the publish transaction, so a publish that rolls back asks nobody. Runs as the
  job runner (`SystemActor.oban/0`) in the organization: asking again is the host's
  consequence of a publish, not a choice anyone makes. The fan-out itself is idempotent per
  review and set of versions, so a retry or a second publish of the same set opens nothing
  new.

  An organization whose policy review has never fallen due has nobody to ask again: the
  first review asks everyone over whatever is current then.

  Args are `%{"organization_id" => id}`, string-keyed (iron law #08), one job per
  organization at a time.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 60, keys: [:organization_id], states: [:available, :scheduled]]

  require Ash.Query

  alias AshEnterprise.Automation.{Occurrence, Occurrences}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Signatures
  alias AshEnterprise.Signatures.Actions.OpenAcknowledgements

  @doc "The job for `organization_id`."
  @spec job(Ecto.UUID.t()) :: Oban.Job.changeset()
  def job(organization_id), do: new(%{"organization_id" => to_string(organization_id)})

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"organization_id" => organization_id}}) do
    opts = [actor: SystemActor.oban(), tenant: organization_id]

    case latest_review(opts) do
      nil ->
        :ok

      review ->
        with {:ok, _tally} <- Signatures.open_acknowledgements(review.id, opts), do: :ok
    end
  end

  # The organization's most recent policy review: the one in progress.
  defp latest_review(opts) do
    type = Occurrences.review_due()

    Occurrence
    |> Ash.Query.filter(type == ^type)
    |> Ash.Query.sort(time: :desc)
    |> Ash.read!(opts)
    |> Enum.find(&OpenAcknowledgements.policy_review?/1)
  end
end
