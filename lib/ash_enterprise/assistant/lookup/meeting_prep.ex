defmodule AshEnterprise.Assistant.Lookup.MeetingPrep do
  @moduledoc """
  One of the person's meetings with what stands open between them and the other
  people in it: replies they owe, replies they are waiting for, their open action
  items from those threads or that meeting, and who they have not met or written
  to before. `prep` says whether any of that is there, and `reasons` says what,
  in words a small model can repeat.

  Computed, never stored: `meeting_prep` is a manual read
  (`AshEnterprise.Assistant.Lookups.MeetingPrep`) over the canonical reads, made
  as the person, behind the zone gate. See `AshEnterprise.Assistant.Lookup`.
  """

  use AshEnterprise.Platform.Resource,
    domain: AshEnterprise.Assistant,
    data_layer: Ash.DataLayer.Simple,
    ownership: :none,
    tenant?: false,
    lifecycle?: false,
    archival?: false,
    audit?: false,
    self_service: [:meeting_prep],
    extra_extensions: [AshAgent.Effects]

  alias AshEnterprise.Assistant.Lookups

  resource do
    require_primary_key? false
  end

  attributes do
    attribute :ref, :string, public?: true
    attribute :title, :string, public?: true
    attribute :when, :string, public?: true
    attribute :where, :string, public?: true
    attribute :attendees, {:array, :string}, public?: true
    attribute :prep, :boolean, public?: true
    attribute :reasons, {:array, :string}, public?: true
    attribute :replies_owed, {:array, :map}, public?: true
    attribute :waiting_on_them, {:array, :map}, public?: true
    attribute :open_items, {:array, :map}, public?: true
    attribute :not_met_before, {:array, :string}, public?: true
  end

  actions do
    read :meeting_prep do
      description "The person's meetings in a window, each with what to prepare."

      argument :window, :string do
        allow_nil? true
        description Lookups.Support.window_help() <> " Default tomorrow."
      end

      argument :text, :string do
        allow_nil? true
        description "Text to find in the meeting title."
      end

      manual Lookups.MeetingPrep
    end
  end

  effects do
    action :meeting_prep,
      kind: :read,
      read_only?: true,
      destructive?: false,
      idempotent?: true,
      open_world?: false,
      intent: :inspect
  end
end
