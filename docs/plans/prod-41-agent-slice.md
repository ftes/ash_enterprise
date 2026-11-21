# The agent chat: a useful slice (PROD-41)

**Status: built.** Written on 2026-11-21, after most of the design below had already shipped (PROD-42 to
PROD-47, AGT-61, AGT-105/106). It is a design record, not a forecast (see the README's note on plans
written afterwards). It says how the agent chat at `/app/agent` is put together and what it refuses.
It also covers what the 2026-11-21 slice added for the three questions the epic names, and what is
still missing before it can be used daily.

The doctrine it implements is unchanged: agents are users ([manifesto 05](../manifesto/05-agents-are-users.md)),
writes are approved by the person ([ADR 0015](../adr/0015-approvals-stay-in-ash.md),
[ADR 0055](../adr/0055-consequential-acts-are-governed-invocations.md)), no hosted model sees admitted
data ([ADR 0042](../adr/0042-in-zone-inference-leaving-the-zone-is-a-disclosure.md)), and the model calls
typed actions, never other agents.

## 1. The conversation

| Piece | Where | What it holds |
|---|---|---|
| A thread | `AshEnterprise.Assistant.Thread` | One conversation, owner-only and self-service (ADR 0052). Its title is sealed under an erasure scope of its own (ADR 0024). |
| A turn | `AshEnterprise.Assistant.Turn` | Append-only. The question or the answer, the lookups it made, the refs the tools returned (`refs`) and the scopes those came from. The text is sealed under the thread's scope. |
| An answer | `AshEnterprise.Execution.Run` of the published assistant agent (ADR 0056) | Each question is one durable run, asked, followed and settled by `AshEnterprise.Assistant.Ask`. |

Both resources sit on `AshEnterprise.Platform.Resource`. A turn whose source scope has been shredded is
withheld from history (`Assistant.History`). Earlier turns go into the next run as its input
(`Assistant.Prompt.input/3`), not as model memory, so a shred also removes them from later context.

## 2. The tool loop

The assistant is `AshEnterprise.Assistant.Agent`, an `AshAgent.Agent` declared in code and published per
tenant under four eyes, or under the `:small_team` posture. Each answer is a run of that published
version:

- **Model.** The `in_zone_generative` profile only, called through `AI.Models.GuardedReqLLM`. Every call
  is recorded as an `AI.ModelCall` (caller `assistant`). A target outside the zone is refused and
  recorded. There is no hosted fallback.
- **Limits.** 6 model steps, 12 tool calls, 5 minutes, a 200k token budget and one repair of an empty
  answer. A run that reaches a limit fails and says why. It is not lifted.
- **Reads.** Each read is a computed `:read` on a resource under `Assistant.Lookup`, exposed as an
  `ash_ai` tool. It runs the canonical model's own read actions as the asking person
  (`authorize?: true`). Rows are typed, few fields wide, and carry a ref. Before reading anything, each
  read passes the zone gate (`Assistant.ZoneGate`): content goes only to a run whose model is in the
  canonical store's zone. Any other caller, such as an MCP client or a hosted agent, gets a refusal.
- **Policies.** These are the same row policies as everywhere else. Mail, Slack, calendar and contacts
  are owner-only, so another person's rows never reach the tool, whatever their role. The tools add no
  authorization of their own and none of their checks query (CLAUDE.md non-negotiable 3).

## 3. Citations

The model cites `[[surface:id]]`. `Assistant.Answer` turns a citation into a link only when the run's
tools returned that ref (`Ask.refs_in/1` collects every `"ref"`, nested ones included). Any other
citation is dropped. A link goes to `/app/r/<surface>/<id>`, which re-reads the record as whoever
follows it.

## 4. Composed surfaces

`compose_surface` asks for a table, calendar or board of the person's own records. The server writes the
`AshA2ui.Dynamic` spec from a curated catalogue and verifies it against the allowlist. It renders inline
as the person. Pinning stores the spec as a `PinnedApp` (owner-only), which is re-verified on every load.

## 5. Writes stay requests

Nine targets declare `approval: :confirm`: add or finish an action item, draft a reply, sync an account,
approve or reject a task, and merge, keep separate or mark unsure a duplicate. A run never executes one.
A call becomes an `Execution.Invocation` requested as the person, waiting on an approval task whose only
candidate is that person, and the answer ends there. Confirm on the page runs the action once, as them,
and audits it (`Assistant.Requests`). A reply draft is stored and never sent. No send scope exists.

## 6. What it refuses

- A model outside the zone, or none configured: the chat says so plainly.
- Another person's records: they are absent from every result, so the model can neither cite nor ask
  about them.
- A decision that is not the person's: the request is refused before anything is shown.
- Text in mail or events that tries to instruct it: tool results are data. No tool writes in the loop,
  so an injected instruction has nothing to act with.
- Sending, deleting, or calling another agent: none of these is a tool.

## 7. The 2026-11-21 slice: the three daily questions

The epic's done criterion names three questions. Here is how each one stood before this slice:

| Question | Before | This slice |
|---|---|---|
| "What did X ask me for this week?" | `read_messages` by person and window | An eval case (`asked_this_week`), so a regression shows |
| "Who am I waiting on?" | No tool: `needs_reply` is the inverse | `find_conversations` with `waiting_on_others`: threads the person wrote last in (email, DMs, group DMs), last 30 days by default, longest wait first, each naming who it waits on and since when |
| "Which meetings tomorrow need prep?" | `calendar_events` returned bare events | A `meeting_prep` read: per meeting, replies owed to the people in it, replies awaited from them, open action items from those threads or the meeting, and people not met before, plus `prep` and `reasons` |

How the slice decides:

- **The person themself is never one of "the others".** `Support.my_people/1` reads, as the person, the
  contact with their sign-in address and the senders of their own sent messages.
- **Thresholds.** `meeting_prep` treats a meeting with more than 15 other people as an all-hands: only
  its own action items are looked for. Threads count if they are from the last 90 days and are not
  channel posts.
- **Deterministic answers.** `prep` and `reasons` are computed, not judged. The model names the meetings
  and repeats the reasons, citing the refs on each.

Proven by `test/ash_enterprise/assistant/daily_questions_test.exs`, which runs over synthetic data and
covers what each tool returns, that the person is left out, that another person gets nothing, and the
zone gate. Three eval cases (`asked_this_week`, `waiting_on`, `meeting_prep`) run in the scripted
eval in CI and against the in-zone model with `mix ash_enterprise.assistant.eval`.

## 8. Not yet (follow-ups filed under PROD-41)

- **"What did X ask me for" as a read of requests (PROD-49).** Today it is the model reading raw messages. A
  request-extraction pass over inbound mail would make it a list, the counterpart of the commitments
  proposer (ADR 0047) for what others asked of the person.
- **Prep as a surface (PROD-50).** `meeting_prep` answers in text. A composed "tomorrow" board, with meetings in
  rows and the open items beside them, would be a surface worth pinning.
- **Proposing from prep (PROD-51).** "Draft the reply Quinn is owed" and "add an action item to prepare" should
  be one step from a prep row. The targets exist, but the prompt and evals do not cover chaining them.
- **Nudges (PROD-51).** A draft follow-up for a thread waited on more than N days, proposed like any other draft.
- **A daily-use log (PROD-52).** Counts and kinds of failed real questions (PROD-46's dogfood log), so "used
  daily" is measured rather than asserted.
- **Who reads a member's calendar (PROD-53).** `CalendarEvent` and `Task` are not in
  `Security.Privilege`'s owner-only list, though `EventAttendee`, `Conversation`, `Message` and
  `Person` are. A tenant Administrator therefore reads another member's events and action items, and so
  does every tool run as them. Mail, Slack, contacts and attendee lists stay out of the answer.
  Whether those two should be owner-only is an authorization decision, left open here.
