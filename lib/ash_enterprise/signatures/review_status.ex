defmodule AshEnterprise.Signatures.ReviewStatus do
  @moduledoc """
  Who has and has not acknowledged the policies, for one policy review: the occurrence that
  opened it (`AshEnterprise.Signatures.Request.open_acknowledgements`).

  Each person the review asked is counted once, by the newest request it sent them (a policy
  published after the review opened sends a second one), in one of four places:

  | Bucket | The person's newest request for this review |
  |---|---|
  | `acknowledged` | they signed it, and it named every current policy version |
  | `outstanding` | it is still open, waiting on them (`notified` or `viewed`), or they signed it but a version it named has since been replaced (`earlier version`) |
  | `declined` | they declined it |
  | `ended` | it ended without them: cancelled by a later review, expired or recalled |

  A signature over a version that is no longer current is not counted as acknowledged: the
  controls say that person is out (`AshEnterprise.Compliance.PolicyAcknowledgement`), and
  the review says the same. Publishing a new version asks them again
  (`AshEnterprise.Signatures.ReaskWorker`), and that newer request then decides their place.

  Everything is read as the caller, so a reader who may not see the requests sees nobody.
  The administrator's review task shows this (`AshEnterprise.Bpmn.Calculations.SubjectSummary`)
  so the person closing the review has the list in front of them. Closing the review records
  their decision only: it acknowledges nothing for anyone, and the people outstanding stay
  outstanding.

  A person is named by the email sealed on their signer row, so a person who has been erased
  reads as erased here too.
  """

  require Ash.Query

  alias AshEnterprise.Signatures.Request

  @open [:draft, :sent, :partially_signed]
  @buckets ["acknowledged", "outstanding", "declined", "ended"]

  @type t :: %{String.t() => term()}

  @doc """
  The review's status, read as `opts`' actor: `%{"acknowledged" => [...], "outstanding" =>
  [...], "declined" => [...], "ended" => [...], "counts" => %{...}, "asked" => n, "versions" => n}`. Each
  person is `%{"user_id", "email", "state", "at"}`, sorted by email.
  """
  @spec status(Ash.UUID.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def status(occurrence_id, opts) do
    with {:ok, requests} <- requests(occurrence_id, opts),
         {:ok, policies} <- AshEnterprise.Compliance.current_policies(opts) do
      current = MapSet.new(policies, & &1.sha256)

      people =
        requests
        |> Enum.group_by(&person/1)
        |> Enum.reject(fn {user_id, _} -> is_nil(user_id) end)
        |> Enum.map(fn {_user_id, theirs} -> theirs |> newest() |> entry(current) end)
        |> Enum.sort_by(&{&1["email"], &1["user_id"]})

      grouped = Enum.group_by(people, & &1["bucket"], &Map.delete(&1, "bucket"))
      by_bucket = Map.new(@buckets, &{&1, Map.get(grouped, &1, [])})

      {:ok,
       Map.merge(by_bucket, %{
         "counts" => Map.new(by_bucket, fn {bucket, list} -> {bucket, length(list)} end),
         "asked" => length(people),
         "versions" => versions(requests)
       })}
    end
  end

  @doc "The status as text for the person deciding the review."
  @spec describe(t()) :: String.t()
  def describe(%{"asked" => 0}),
    do: "Nobody has been asked to acknowledge the policies for this review yet."

  def describe(%{"counts" => counts, "asked" => asked} = status) do
    summary =
      "#{counts["acknowledged"]} of #{asked} acknowledged · #{counts["outstanding"]} outstanding"

    sections =
      for {bucket, title} <- [
            {"outstanding", "Outstanding"},
            {"acknowledged", "Acknowledged"},
            {"declined", "Declined"},
            {"ended", "No longer asked"}
          ],
          (list = status[bucket]) != [] do
        Enum.join(["#{title} (#{length(list)}):" | Enum.map(list, &line/1)], "\n")
      end

    footer =
      "Closing this review records your decision only. It acknowledges nothing for anyone: " <>
        "the people outstanding stay outstanding."

    Enum.join([summary | sections] ++ [footer], "\n\n")
  end

  @doc "One line: `2 of 3 acknowledged · 1 outstanding`."
  @spec outline(t()) :: String.t()
  def outline(%{"counts" => counts, "asked" => asked}),
    do:
      "#{counts["acknowledged"]} of #{asked} acknowledged · #{counts["outstanding"]} outstanding"

  defp line(%{"email" => email, "state" => state, "at" => nil}), do: "  #{email} (#{state})"
  defp line(%{"email" => email, "state" => state, "at" => at}), do: "  #{email} (#{state} #{at})"

  defp requests(occurrence_id, opts) do
    Request
    |> Ash.Query.filter(occurrence_id == ^occurrence_id)
    |> Ash.Query.load([:documents, signers: [:email]])
    |> Ash.read(opts)
  end

  defp person(%{signers: [signer | _]}), do: signer.user_id
  defp person(_request), do: nil

  # uuid v7 ids order by creation.
  defp newest(requests), do: Enum.max_by(requests, & &1.id)

  defp entry(%{signers: [signer | _]} = request, current) do
    {bucket, state, at} = place(request, signer, current)

    %{
      "bucket" => bucket,
      "user_id" => signer.user_id,
      "email" => to_string(signer.email),
      "state" => state,
      "at" => at && DateTime.to_date(at) |> Date.to_iso8601()
    }
  end

  defp place(request, %{status: :signed} = signer, current) do
    if MapSet.subset?(current, MapSet.new(request.documents, & &1.source_sha256)),
      do: {"acknowledged", "signed", signer.signed_at},
      else: {"outstanding", "earlier version", signer.signed_at}
  end

  defp place(_request, %{status: :declined} = signer, _current),
    do: {"declined", "declined", signer.ended_at}

  defp place(%{status: status}, %{status: signer_status}, _current)
       when status in @open and signer_status in [:pending, :notified, :viewed],
       do: {"outstanding", Atom.to_string(signer_status), nil}

  defp place(request, _signer, _current),
    do: {"ended", Atom.to_string(request.status), request.ended_at}

  defp versions(requests) do
    requests
    |> Enum.flat_map(fn request -> Enum.map(request.documents, & &1.source_sha256) end)
    |> Enum.uniq()
    |> length()
  end
end
