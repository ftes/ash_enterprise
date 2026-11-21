defmodule AshEnterprise.Assistant.Lookups.MeetingPrep do
  @moduledoc """
  `Lookup.MeetingPrep.meeting_prep`: the person's meetings in a window (default
  `tomorrow`), each with what stands open between them and the other people in
  it, so "which meetings tomorrow need prep" is one call and the answer is the
  person's own records rather than a guess.

  For each meeting that is not cancelled (at most #{15}), the other people in it
  are its attendees and organizer, less the person themself
  (`Support.my_people/1`). Against them, all read as the person:

    * **replies owed** — email threads and DMs from the last #{90} days whose
      latest message is from one of them;
    * **waiting on them** — the same, where the person wrote last;
    * **open items** — the person's open action items that came from the meeting
      itself or from one of those threads (`Canonical.Task` `origin_id`);
    * **not met before** — people with no meeting with the person in the year
      before the window, no conversation with them and no message from them.

  A meeting with more than #{15} other people is an all-hands: only its own
  action items are looked for. `prep` is true when any of the above is there,
  and `reasons` says what in short sentences. At most #{3} of each kind are
  listed, each with a ref the answer cites. Channel posts are left out: they wait
  on nobody in particular.
  """

  use Ash.Resource.ManualRead

  require Ash.Query

  alias AshEnterprise.Assistant.Lookup
  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Canonical.{CalendarEvent, Conversation, Message, Person, Task}

  @scan 200
  @shown 15
  @crowd 15
  @people 100
  @threads 300
  @each 3
  @lookback_days 90
  @met_days 365
  @channels [:public_channel, :private_channel]

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    Support.gated(query, context, &lookup(query.arguments, &1))
  end

  defp lookup(args, opts) do
    with {:ok, {from, _to} = bounds} <- bounds(args[:window]),
         {:ok, events} <- events(bounds, opts) do
      events =
        events
        |> Enum.filter(
          &(&1.status != :cancelled and Support.matches?(Support.text(&1.title), args[:text]))
        )
        |> Enum.take(@shown)

      me = Support.my_people(opts)
      others = Map.new(events, &{&1.id, others(&1, me)})
      ids = looked_at(others)

      with {:ok, threads} <- threads(ids, opts),
           {:ok, items} <- open_items(opts),
           {:ok, unmet} <- not_met(ids, from, opts) do
        context = %{threads: threads, items: items, unmet: unmet}
        {:ok, Enum.map(events, &row(&1, Map.fetch!(others, &1.id), context))}
      end
    end
  end

  defp bounds(window) do
    case Support.window(window) do
      :none -> Support.window("tomorrow")
      other -> other
    end
  end

  defp events({from, to}, opts) do
    CalendarEvent
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(starts_at < ^to and ends_at > ^from)
    |> Ash.Query.sort(starts_at: :asc)
    |> Ash.Query.limit(@scan)
    |> Ash.Query.load([
      :when,
      organizer: Ash.Query.load(Person, [:label]),
      people: Ash.Query.load(Person, [:label])
    ])
    |> Ash.read(opts)
  end

  # The meeting's attendees and organizer other than the person, once each.
  defp others(event, me) do
    [loaded_one(event.organizer) | loaded(event.people)]
    |> Enum.reject(&(is_nil(&1) or MapSet.member?(me, &1.id)))
    |> Enum.uniq_by(& &1.id)
  end

  # The people whose threads and history are read: those in meetings small
  # enough for a thread with one of them to be about the meeting.
  defp looked_at(others) do
    others
    |> Map.values()
    |> Enum.reject(&crowd?/1)
    |> List.flatten()
    |> Enum.map(& &1.id)
    |> Enum.uniq()
    |> Enum.take(@people)
  end

  defp crowd?(people), do: length(people) > @crowd

  # Recent threads with any of `ids`, each with its newest message and the
  # people taking part, as the person reads them.
  defp threads([], _opts), do: {:ok, []}

  defp threads(ids, opts) do
    since = DateTime.add(DateTime.utc_now(), -@lookback_days, :day)

    Conversation
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(exists(people, id in ^ids) or exists(messages, sender_id in ^ids))
    |> Ash.Query.filter(exists(messages, sent_at >= ^since))
    |> Ash.Query.sort(last_message_at: :desc_nils_last)
    |> Ash.Query.limit(@threads)
    |> Ash.Query.load(
      people: Ash.Query.select(Person, [:id]),
      messages:
        Message
        |> Ash.Query.sort(sent_at: :desc)
        |> Ash.Query.limit(1)
        |> Ash.Query.load([:sender_label])
    )
    |> Ash.read(opts)
    |> case do
      {:ok, threads} -> {:ok, Enum.reject(threads, &(&1.kind in @channels or latest(&1) == nil))}
      error -> error
    end
  end

  # The person's open action items that came from a record, by that record.
  defp open_items(opts) do
    Task
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(status == :open and not is_nil(origin_id))
    |> Ash.Query.sort(due_at: :asc_nils_last, inserted_at: :desc)
    |> Ash.Query.limit(@scan)
    |> Ash.Query.load(:label)
    |> Ash.read(opts)
    |> case do
      {:ok, tasks} -> {:ok, Enum.group_by(tasks, & &1.origin_id)}
      error -> error
    end
  end

  # Of `ids`, those with no meeting with the person in the year before `from`
  # and no conversation with them.
  defp not_met([], _from, _opts), do: {:ok, MapSet.new()}

  defp not_met(ids, from, opts) do
    since = DateTime.add(from, -@met_days, :day)

    with {:ok, earlier} <- earlier_events(ids, since, from, opts),
         {:ok, people} <- conversation_counts(ids, opts) do
      met = MapSet.new(Enum.flat_map(earlier, &event_people/1))

      {:ok,
       people
       |> Enum.reject(&(MapSet.member?(met, &1.id) or written?(&1)))
       |> MapSet.new(& &1.id)}
    end
  end

  defp written?(person),
    do: (person.conversation_count || 0) + (person.sent_message_count || 0) > 0

  defp earlier_events(ids, since, until, opts) do
    CalendarEvent
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(starts_at >= ^since and starts_at < ^until)
    |> Ash.Query.filter(organizer_id in ^ids or exists(people, id in ^ids))
    |> Ash.Query.limit(@scan * 2)
    |> Ash.Query.load(people: Ash.Query.select(Person, [:id]))
    |> Ash.read(opts)
  end

  defp event_people(event), do: [event.organizer_id | Enum.map(loaded(event.people), & &1.id)]

  defp conversation_counts(ids, opts) do
    Person
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.load([:conversation_count, :sent_message_count])
    |> Ash.read(opts)
  end

  defp row(event, others, context) do
    small? = not crowd?(others)
    ids = MapSet.new(others, & &1.id)
    threads = if small?, do: Enum.filter(context.threads, &with_any?(&1, ids)), else: []

    {owed, waiting} = Enum.split_with(threads, &(latest(&1).direction == :inbound))
    owed = owed |> Enum.filter(&MapSet.member?(ids, latest(&1).sender_id)) |> Enum.take(@each)
    waiting = Enum.take(waiting, @each)

    items =
      [event.id | Enum.map(threads, & &1.id)]
      |> Enum.flat_map(&Map.get(context.items, &1, []))
      |> Enum.uniq_by(& &1.id)
      |> Enum.take(@each)

    unmet = if small?, do: Enum.filter(others, &MapSet.member?(context.unmet, &1.id)), else: []

    reasons =
      Enum.map(owed, &"you owe #{from(&1)} a reply on #{quoted(&1.subject)}") ++
        Enum.map(waiting, &"you are waiting for a reply on #{quoted(&1.subject)}") ++
        Enum.map(items, &"open action item: #{Support.clip(&1.label, 120)}") ++
        Enum.map(unmet, &"first meeting with #{name(&1)}")

    Support.row(Lookup.MeetingPrep, %{
      ref: Support.ref(CalendarEvent, event),
      title: Support.clip(event.title, 160),
      when: event.when,
      where: Support.clip(event.location, 120),
      attendees: others |> Enum.map(&name/1) |> Enum.take(8),
      prep: reasons != [],
      reasons: reasons,
      replies_owed: Enum.map(owed, &thread(&1, %{from: from(&1)})),
      waiting_on_them: Enum.map(waiting, &thread(&1, %{since: stamp(&1)})),
      open_items: Enum.map(items, &item/1),
      not_met_before: Enum.map(unmet, &name/1)
    })
  end

  defp with_any?(thread, ids) do
    MapSet.member?(ids, latest(thread).sender_id) or
      Enum.any?(loaded(thread.people), &MapSet.member?(ids, &1.id))
  end

  defp thread(thread, extra) do
    Support.compact(
      Map.merge(
        %{subject: Support.clip(thread.subject, 120), ref: Support.ref(Conversation, thread)},
        extra
      )
    )
  end

  defp item(task),
    do: Support.compact(%{title: Support.clip(task.label, 120), ref: Support.ref(Task, task)})

  defp from(thread), do: Support.text(latest(thread).sender_label) || "someone"
  defp stamp(thread), do: AshEnterprise.Platform.LocalTime.stamp(latest(thread).sent_at)
  defp name(person), do: Support.text(person.label) || "someone"
  defp quoted(subject), do: ~s{"#{Support.clip(subject, 120) || "(no subject)"}"}

  defp latest(%{messages: [message | _]}), do: message
  defp latest(_thread), do: nil

  defp loaded(list) when is_list(list), do: list
  defp loaded(_not_loaded), do: []

  defp loaded_one(%Person{} = person), do: person
  defp loaded_one(_none), do: nil
end
