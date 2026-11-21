defmodule AshEnterprise.Assistant.Lookups.Conversations do
  @moduledoc """
  `Lookup.Conversation.find_conversations`: the person's Gmail threads and Slack
  conversations, newest activity first.

  Everything is read as the person through the canonical read actions
  (`Conversation.read` / `:gmail` / `:slack`, `Message.read`), so only
  their own, zone-admitted rows exist here at all (owner-only, ADR 0042):
  content the zone gate refused at projection was never written, and
  another person's mail is filtered out by the read, not by this module.

  * **person** — a participant (the derived `people` joins) or a sender,
    matched in SQL on the person's name and address (plaintext columns).
  * **window** — the thread had a message sent in it.
  * **text** — subject and message bodies are sealed, so they are matched
    after the read, on decrypted values: up to #{300} threads and #{2000}
    messages are scanned.
  * **needs_reply** — the thread's latest message is inbound (someone
    else's), read from each thread's newest message.
  * **waiting_on_others** — the other way round: the person wrote last and
    nobody has answered, in email, DMs and group DMs (a channel post waits on
    nobody in particular). The window defaults to `last_30_days`, the longest
    wait comes first, and each row names who the thread is waiting on: its
    participants other than the person (`Support.my_people/1`).
  """

  use Ash.Resource.ManualRead

  require Ash.Query

  alias AshEnterprise.Assistant.Lookup
  alias AshEnterprise.Assistant.Lookups.Support
  alias AshEnterprise.Canonical.{Conversation, Message, Person}
  alias AshEnterprise.Platform.LocalTime

  @scan 300
  @message_scan 2000
  @shown 25

  @impl true
  def read(query, _data_layer_query, _opts, context) do
    Support.gated(query, context, &lookup(query.arguments, &1))
  end

  defp lookup(args, opts) do
    waiting? = args[:waiting_on_others] == true

    with {:ok, bounds} <- optional_window(args[:window], waiting?),
         {:ok, threads} <- read_threads(args, bounds, waiting?, opts),
         {:ok, threads} <- by_text(threads, args[:text], bounds, opts) do
      me = if waiting?, do: Support.my_people(opts), else: MapSet.new()

      {:ok,
       threads
       |> awaiting_reply(args[:needs_reply])
       |> waiting_on_others(waiting?)
       |> Enum.take(@shown)
       |> Enum.map(&row(&1, me, waiting?))}
    end
  end

  defp awaiting_reply(threads, true), do: Enum.filter(threads, &needs_reply?/1)
  defp awaiting_reply(threads, _any), do: threads

  # The person wrote last, outside a channel; the longest wait first.
  defp waiting_on_others(threads, false), do: threads

  defp waiting_on_others(threads, true) do
    threads
    |> Enum.filter(&(waiting?(&1) and &1.kind not in [:public_channel, :private_channel]))
    |> Enum.sort_by(&latest(&1).sent_at, DateTime)
  end

  defp optional_window(window, waiting?) do
    case Support.window(window) do
      :none when waiting? -> Support.window("last_30_days")
      :none -> {:ok, nil}
      other -> other
    end
  end

  defp read_threads(args, bounds, waiting?, opts) do
    Conversation
    |> Ash.Query.for_read(action(args[:source]), %{}, opts)
    |> Ash.Query.sort(last_message_at: :desc_nils_last)
    |> by_person(args[:person])
    |> in_window(bounds)
    |> Ash.Query.limit(@scan)
    |> Ash.Query.load([
      :message_count,
      :last_message_at,
      :last_activity,
      :kind_label,
      messages:
        Message
        |> Ash.Query.sort(sent_at: :desc)
        |> Ash.Query.limit(1)
        |> Ash.Query.load([:sender_label])
    ])
    |> participants(waiting?)
    |> Ash.read(opts)
  end

  # Who a waiting thread waits on: its participants, read as the person.
  defp participants(query, false), do: query

  defp participants(query, true),
    do: Ash.Query.load(query, people: Ash.Query.load(Person, [:label]))

  defp action(:gmail), do: :gmail
  defp action(:slack), do: :slack
  defp action(_any), do: :read

  defp by_person(query, person) when person in [nil, ""], do: query

  defp by_person(query, person) do
    pattern = Support.like(person)
    # Addresses are sealed: matched whole, through their blind index.
    address = AshEnterprise.Erasure.BlindIndex.of(query.tenant, person)

    Ash.Query.filter(
      query,
      exists(people, ilike(name, ^pattern) or email_bidx == ^address) or
        exists(messages.sender, ilike(name, ^pattern) or email_bidx == ^address)
    )
  end

  defp in_window(query, nil), do: query

  defp in_window(query, {from, to}),
    do: Ash.Query.filter(query, exists(messages, sent_at >= ^from and sent_at < ^to))

  defp by_text(threads, text, _bounds, _opts) when text in [nil, ""], do: {:ok, threads}

  defp by_text(threads, text, bounds, opts) do
    ids = Enum.map(threads, & &1.id)

    with {:ok, hits} <- body_hits(ids, text, bounds, opts) do
      {:ok,
       Enum.filter(threads, fn thread ->
         Support.matches?(Support.text(thread.subject), text) or MapSet.member?(hits, thread.id)
       end)}
    end
  end

  # The threads (among `ids`) holding a message whose decrypted body matches.
  defp body_hits([], _text, _bounds, _opts), do: {:ok, MapSet.new()}

  defp body_hits(ids, text, bounds, opts) do
    Message
    |> Ash.Query.for_read(:read, %{}, opts)
    |> Ash.Query.filter(conversation_id in ^ids)
    |> sent_in(bounds)
    |> Ash.Query.sort(sent_at: :desc)
    |> Ash.Query.limit(@message_scan)
    |> Ash.read(opts)
    |> case do
      {:ok, messages} ->
        {:ok,
         messages
         |> Enum.filter(&Support.matches?(Support.text(&1.body), text))
         |> MapSet.new(& &1.conversation_id)}

      error ->
        error
    end
  end

  defp sent_in(query, nil), do: query
  defp sent_in(query, {from, to}), do: Ash.Query.filter(query, sent_at >= ^from and sent_at < ^to)

  defp latest(%{messages: [message | _]}), do: message
  defp latest(_thread), do: nil

  defp needs_reply?(thread), do: match?(%{direction: :inbound}, latest(thread))
  defp waiting?(thread), do: match?(%{direction: :outbound}, latest(thread))

  defp row(thread, me, waiting?) do
    last = latest(thread)

    Support.row(Lookup.Conversation, %{
      ref: Support.ref(Conversation, thread),
      id: thread.id,
      source: thread.external_system,
      kind: thread.kind_label,
      subject: Support.clip(thread.subject, 160),
      last_activity: thread.last_activity,
      messages: thread.message_count,
      last_from: last && from(last),
      last_preview: last && Support.clip(last.body, 140),
      needs_reply: needs_reply?(thread),
      waiting_on: if(waiting?, do: others(thread, me, last)),
      waiting_since: if(waiting?, do: LocalTime.stamp(last.sent_at))
    })
  end

  # The thread's participants other than the person, by name: the sender of
  # their own latest message is them too, whatever address it came from.
  defp others(thread, me, last) do
    me = MapSet.put(me, last.sender_id)

    thread.people
    |> List.wrap()
    |> Enum.reject(&MapSet.member?(me, &1.id))
    |> Enum.map(&Support.text(&1.label))
    |> Enum.reject(&is_nil/1)
    |> Enum.take(5)
  end

  @doc false
  def from(%{direction: :outbound}), do: "me"
  def from(message), do: Support.text(message.sender_label) || "unknown sender"
end
