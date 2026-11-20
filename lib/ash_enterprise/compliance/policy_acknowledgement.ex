defmodule AshEnterprise.Compliance.PolicyAcknowledgement do
  @moduledoc """
  How a person's acknowledgement of the policies becomes compliance events (ADR 0035), for
  the criteria the yearly policy review serves: CC1.1, CC2.2 and CC5.3.

  Two moments append events to `AshEnterprise.Compliance.EventLog`, one per criterion:

    * **`policy_acknowledged`**: a person signs an acknowledgement request whose documents
      include a policy version (`AshEnterprise.Compliance.Changes.RecordPolicyAcknowledgement`,
      on the signer's `sign`). The event names the request and the policy versions it
      showed: key, version and SHA-256.
    * **`policy_published`**: a new policy version is minted
      (`AshEnterprise.Compliance.Changes.ReviewPolicyAcknowledgements`, on the policy's
      `mint`). Every person in scope is evaluated again, so a person who held version 1 is
      out once version 2 is current, and stays out until they acknowledge it.

  `AshEnterprise.Compliance.PolicyAcknowledgementProjector` folds them into one finding per
  person and criterion. Nothing here evaluates a rule: each event carries the person's
  standing as facts (`standing/2`), and the rules read them.

  ## The standing

  A person holds a policy version when a request with purpose `:acknowledge` that they
  signed showed its document (`source_version_id` and `source_sha256` equal to the
  policy's `document_version_id` and `sha256`). The same bytes republished under a later
  version are the same document, so an acknowledgement of them is held.

    * every current policy held: `acknowledged_current_policies` is `true` (in);
    * some policy acknowledged here, but not every current one at its current version:
      `false` (out);
    * no policy ever acknowledged, or no policy published: the fact is absent, and the
      finding is unknown. Never a pass.

  A superseded acknowledgement is not edited or removed: the version-1 signer row, its
  events and its completion stay as they were.

  ## In scope

  Every active user of the organization (`in_scope_users/1`). A role or team filter is a
  later choice.

  ## Trusted machinery

  The reads here are bookkeeping inside an authorized write (a person's `sign`, an
  administrator's `publish`), and the person reading their own standing is not the
  question: they run without authorization, and the events are appended by the system
  actor, which the event log's policy admits.
  """

  require Ash.Query

  alias AshEnterprise.Accounts.{BusinessUnit, User}
  alias AshEnterprise.Compliance.{EventLog, Policy}
  alias AshEnterprise.Platform.SystemActor
  alias AshEnterprise.Signatures.Signer

  @subject_type "user"
  @fact_subject "person"
  @controls ["CC1.1", "CC2.2", "CC5.3"]

  @doc "The criteria this module's events are evaluated for, one finding per person each."
  def controls, do: @controls

  @doc "The finding subject type: a user of the organization."
  def subject_type, do: @subject_type

  @doc """
  Records a signed acknowledgement: one `policy_acknowledged` event per criterion for the
  signer's person, naming the request and the policy versions it showed.

  `:skip` when the request is not an acknowledgement or shows no policy version: such a
  request is someone else's use of signatures, and says nothing about the policies.
  """
  @spec record_signed(Signer.t() | map(), keyword()) :: :ok | :skip | {:error, term()}
  def record_signed(%{organization_id: organization_id, user_id: user_id} = signer, opts \\ []) do
    request = load_request(organization_id, signer.request_id)

    with %{purpose: :acknowledge} <- request,
         [_ | _] = shown <- shown_policies(organization_id, request.documents) do
      data = %{
        "request_id" => request.id,
        "signer_id" => signer.id,
        "signed_at" => signer.signed_at && DateTime.to_iso8601(signer.signed_at),
        "policies" => Enum.map(shown, &policy_data/1)
      }

      record(organization_id, user_id, :policy_acknowledged, data, opts)
    else
      _ -> :skip
    end
  end

  @doc """
  Evaluates every person in scope again after `policy` was minted: one `policy_published`
  event per person and criterion.
  """
  @spec record_published(Policy.t(), keyword()) :: :ok | {:error, term()}
  def record_published(%Policy{organization_id: organization_id} = policy, opts \\ []) do
    data = %{"published" => policy_data(policy)}

    organization_id
    |> in_scope_users()
    |> Enum.reduce_while(:ok, fn user, :ok ->
      case record(organization_id, user.id, :policy_published, data, opts) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  @doc """
  The person's standing against the organization's current policies, as the facts and the
  per-policy detail an event carries. See the moduledoc for what each value means.
  """
  @spec standing(Ecto.UUID.t(), Ecto.UUID.t()) :: %{
          facts: list(),
          current: [map()],
          acknowledged_current_policies: boolean() | nil
        }
  def standing(organization_id, user_id) do
    policies = all_policies(organization_id)
    current = Enum.filter(policies, &is_nil(&1.superseded_at))
    held = held_documents(organization_id, user_id)

    acknowledged? =
      cond do
        current == [] -> nil
        Enum.all?(current, &held?(&1, held)) -> true
        Enum.any?(policies, &held?(&1, held)) -> false
        true -> nil
      end

    facts =
      if is_nil(acknowledged?),
        do: [],
        else: [[@fact_subject, "acknowledged_current_policies", acknowledged?]]

    %{
      facts: facts,
      acknowledged_current_policies: acknowledged?,
      current: Enum.map(current, &Map.put(policy_data(&1), "held", held?(&1, held)))
    }
  end

  @doc "The people the review asks: every active user of the organization."
  @spec in_scope_users(Ecto.UUID.t()) :: [User.t()]
  def in_scope_users(organization_id) do
    # A user belongs to the organization through their business unit (users are not
    # tenant-scoped), and the user carries the unit's id with no relationship to it.
    unit_ids =
      BusinessUnit
      |> Ash.Query.filter(organization_id == ^organization_id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    User
    |> Ash.Query.filter(lifecycle_status == :active and owning_business_unit_id in ^unit_ids)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
  end

  # --- the events --------------------------------------------------------------------

  defp record(organization_id, user_id, action, data, opts) do
    standing = standing(organization_id, user_id)

    occurred_at =
      Keyword.get(opts, :occurred_at) || DateTime.utc_now() |> DateTime.truncate(:second)

    data = Map.put(data, "current", standing.current)

    Enum.reduce_while(@controls, :ok, fn control, :ok ->
      metadata = %{
        "organization_id" => to_string(organization_id),
        "control_id" => control,
        "subject_type" => @subject_type,
        "subject_id" => to_string(user_id),
        "correlation_id" => Keyword.get(opts, :correlation_id),
        "facts" => standing.facts
      }

      # `action:` in the params is the event's action attribute, the thing the projector
      # dispatches on, not the Ash option that names the changeset action.
      EventLog
      |> Ash.Changeset.for_create(
        :create,
        %{
          record_id: Ecto.UUID.generate(),
          resource: :user,
          action: action,
          action_type: :update,
          data: data,
          metadata: metadata,
          occurred_at: occurred_at
        },
        actor: SystemActor.system()
      )
      |> Ash.create()
      |> case do
        {:ok, _event} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  # --- the reads ---------------------------------------------------------------------

  defp load_request(organization_id, request_id) do
    AshEnterprise.Signatures.Request
    |> Ash.Query.filter(id == ^request_id)
    |> Ash.Query.load(:documents)
    |> Ash.read_one!(tenant: organization_id, authorize?: false)
  end

  defp all_policies(organization_id) do
    Policy
    |> Ash.Query.sort(policy_key: :asc, version: :asc)
    |> Ash.read!(tenant: organization_id, authorize?: false)
  end

  # The documents every acknowledgement request the person signed showed, as
  # `{version id, sha256}` pairs.
  defp held_documents(organization_id, user_id) do
    Signer
    |> Ash.Query.filter(
      user_id == ^user_id and status == :signed and request.purpose == :acknowledge
    )
    |> Ash.Query.load(request: :documents)
    |> Ash.read!(tenant: organization_id, authorize?: false)
    |> Enum.flat_map(& &1.request.documents)
    |> MapSet.new(&{&1.source_version_id, &1.source_sha256})
  end

  # The policy versions a request showed, newest version first for each document.
  defp shown_policies(organization_id, documents) do
    shown = MapSet.new(documents, &{&1.source_version_id, &1.source_sha256})

    organization_id
    |> all_policies()
    |> Enum.filter(&held?(&1, shown))
  end

  defp held?(%Policy{document_version_id: id, sha256: sha256}, held),
    do: MapSet.member?(held, {id, sha256})

  defp policy_data(%Policy{} = policy) do
    %{
      "policy_key" => policy.policy_key,
      "version" => policy.version,
      "sha256" => policy.sha256,
      "document_version_id" => policy.document_version_id
    }
  end
end
