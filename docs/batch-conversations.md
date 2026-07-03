# Batch conversations — design reference

> Status: **Phase 1 BUILT + review-hardened; tagging BUILT.** The continuable shared-agent batch
> works (`lua/obelus/batch.lua`), and threads can be **tagged** to curate batch membership. Still to
> build: the **parallel "dispatch all"** mode (one separate agent per thread) and the Phase-2
> meta-thread UI. See "Dispatch modes" and "Tagging" below for the settled model.

## 1. Goal

When several review comments are **related**, send them to **one agent together** so it
reasons about them with shared context, and then **keep talking to that same agent across
rounds** — review its work, add feedback, and have it continue, still holding every thread
in one mind. The point is the *shared context*: one agent, many threads, multiple rounds.

This is distinct from a per-thread chat reply (`<CR>` in the reply box), which is an
isolated 1:1 conversation about a single comment.

## 2. What already exists (build on this, don't reinvent)

- **One-shot batch.** `init.lua M.submit()` → `transport.submit("cli" | default, …)` →
  `transport/cli.lua run_oneshot(payload)`. It sends **all** `store.pending()` comments to a
  single `claude -p` invocation, prompt = `format.to_markdown(comments)` + the review
  protocol, streams the reply, then applies per-comment outcomes from the actions file.
- **The actions protocol.** `actions.lua M.instructions(comments, key)` tells the agent to write
  its own `.ai/review-actions-<key>.json` — one entry **per comment id**: `resolve` /
  `needs_response` / `reply` / `move`. `actions.lua M.apply(key, allowed)` reads it back and
  updates each thread (status + an agent turn), scoped to the ids that dispatch may touch. The
  instructions are already emphatic that it must address **every** comment (shared context, be
  diligent).
- **Session capture + resume.** `claude -p` returns a `session_id`. `run_oneshot` already
  captures it (`transport/cli.lua` ~L168, currently stored **per comment**), and
  `base_cmd(resume, model)` already appends `--resume <session_id>` (cli.lua ~L36). Per-thread
  replies (`init.lua do_respond` ~L139, `resume = c.session_id`) already use it.
- **Per-mode models.** `config.transport.cli.model | fast_model | batch_model`.

**Key insight:** "continue the batch conversation" is mostly *storing and reusing ONE batch
session id* + a good per-round prompt. The agent plumbing is done.

## 3. Core mechanism

One persistent `claude -p` session **per batch**. Round 1 sends all comments and captures
**one** `session_id` (store it on a *batch*, not on each comment). Every later round does
`--resume <batch.session_id>` with a prompt describing what changed, re-injects the actions
protocol, and `actions.apply()`s the result. The session is the agent's memory of all prior
rounds; the prompt only needs to convey the delta.

Fallback when a session is gone (expired / cleaned up): **re-serialize** the full current
state into a fresh prompt (no `--resume`). Same outcome, bigger prompt — keep as a safety net.

## 4. The three ways to talk to the one agent (the user's framing)

All three resume the **same** batch session, so the agent always has the full set in context:

1. **Send all threads together (round 1).** The initial batch. → `run_batch(comments)`.
2. **Continue the batch (round N).** A batch-level follow-up — "here's what I changed,
   keep going." Resumes the session with the round diff. → `continue_batch(message?)`.
3. **Reply inside one thread, routed to the batch agent.** You reply on a single comment,
   but it goes to the **batch** session (so the agent answers *with* the other threads in
   mind), not a fresh per-thread session. The agent's reply is attached to that thread (and
   it may touch others via the actions file). → `reply_into_batch(comment_id, text)`.

(2) and (3) are the same resume; they differ only in how the prompt is scoped ("all" vs
"this thread, but you have the others").

## 4b. Dispatch modes (settled) — two agent topologies × send-scope

There are **two agent topologies**, and you can send one thread or all:

| | one thread | all threads |
|---|---|---|
| **separate agents** (each thread its own isolated session) | dispatch-one (`<prefix>D`, built) | **dispatch-all in parallel** (one agent per thread) — *to build* |
| **shared agent** (one agent holds all threads) | (n/a — a batch of one) | submit batch (`<prefix>s`) + continue (`<prefix>S`) — built |

**The actions file vs streaming is NOT a tradeoff.** Every dispatch already does both: it streams the
agent's live text into the thread *and* reads its own per-job `.ai/review-actions-<key>.json` at the
end for the structured per-thread outcome (resolve / needs_response / reply / move). **Built:** every
dispatch — one-off or batch — gets its own keyed file, so N concurrent dispatches never clobber each
other's write. `key` is the batch id for a batch dispatch (a resumed round remembers the round-1
filename, since the id is per-BATCH not per-round) or the first comment's id for a one-off (a comment
can only be in one live dispatch, so that's collision-free too); `actions.apply(key, allowed)` then
scopes entries to the ids that dispatch may touch. The shared-agent batch writes back to **each
thread individually** via its per-id entry — that per-thread write-back is the reliable mechanism the
single (possibly sub-agent-delegating) orchestrator uses to act on every thread. The future parallel
"dispatch-all" mode (below, to build) reuses this exact mechanism: one keyed file per fanned-out
agent, no new design needed.

## 4c. Tagging (built) — curate which threads are "related"

A batch defaults to "all pending," which assumes they're all related. **Tags make "related" explicit:**

- **Sticky tagging mode** (`store.active_tag`, `<prefix>G` / `:ObelusTagMode`): while on, every NEW
  thread inherits the tag — a fast way to make a run of related threads.
- **Manual tag/untag** any thread, new or existing, to include/exclude it (`<prefix>g` / `:ObelusTag`).
- **Tag-scoped submit**: `<prefix>s` batches the active tag's group (else the cursor thread's tag,
  else all pending). The `Batch` records its `tag`, so `working_set` keeps membership scoped to
  `pending_by_tag(batch.tag)` across rounds. Badged in the thread header + sidebar list.

## 5. The model: do BOTH A and B, switchable (decided)

- **A — "continue batch" key (lightweight).** Store the batch session id; a hotkey resumes
  it with the round diff. Minimal new surface. This is Phase 1.
- **B — first-class Batch object / meta-thread (richer UX).** Model the batch as a durable
  entity shown in the sidebar list as e.g. `▣ Batch #1 (4 threads, round 2)`. Opening it
  shows the cross-thread conversation; you can **reply-to-all** from there, or open any
  member thread. This is Phase 2.
- **Switchable** via config and/or distinct hotkeys (so A users never pay for B).

Anti-pattern to avoid: letting multiple threads each independently `--resume` the *same*
session concurrently — the agent's context forks. Route per-thread follow-ups through the
batch object (mode 3) so there's a single ordered conversation.

## 6. Data model

A new persisted `Batch` record (alongside comments in `store`):

```lua
{
  id          = "<os.time>-<seq>",
  session_id  = "<claude -p session>",   -- THE shared agent session
  comment_ids = { "<id>", … },           -- members (round-1 set; grows/shrinks per round)
  round       = 2,
  transport   = "cli",
  model       = "opus",                  -- batch_model
  status      = "open" | "done",
  created_at  = os.time(),
  rounds      = { { at, summary, applied_n }, … },  -- optional history for the meta-thread UI
}
```

Membership is owned solely by the Batch's `comment_ids` (no back-ref written onto the member
comments — a `comment.batch_id` field was tried and dropped: nothing ever read it, and it went
stale/dangling across deletes). A per-thread reply that needs its batch (mode 3) or the list
badging members looks the Batch up by scanning `comment_ids`, not via a comment-side pointer.

## 7. Config (proposed)

```lua
transport = {
  batch = {
    mode        = "session",   -- "session" (resume, default) | "stateless" (re-serialize) 
    object      = true,        -- create a first-class Batch meta-thread (Option B)
    prompt      = "diff",      -- "diff" (recommended) | "full" | "new"
    -- continue resumes the LAST open batch if one exists, else starts a fresh round-1 batch
  },
}
```

`prompt` decided as **diff** (cheap + unambiguous; the session holds the rest).

## 8. Keymaps (proposed, under `keys.prefix`)

- `<prefix>s` — **submit batch** (round 1): create a Batch from `store.pending()`, capture
  the session id. (Today's submit, upgraded to record the batch.)
- `<prefix>S` — **continue batch** (round N): resume the open batch with the round diff.
  (Currently `<prefix>S` is single-comment dispatch — re-map or pick a free key.)
- From a Batch meta-thread (Option B): `<CR>` reply-to-all; open a member to reply into it.

## 9. Transport changes

- Add `run_batch(payload)` (or a flag on `run_oneshot`) that:
  - takes `payload.opts.resume = batch.session_id` (already supported by `base_cmd`),
  - takes `payload.opts.batch = <Batch>` so it can store the session id on the **batch**,
    not per comment (change cli.lua ~L168 to set `batch.session_id` once),
  - keeps `--output-format stream-json`, the streaming preview, and `actions.apply()`.
- `init.lua`: `M.submit` records/creates the Batch + stores its session id on finish;
  new `M.continue_batch(message?)` and `M.reply_into_batch(id, text)`.

## 10. The per-round prompt (mode 2/3, "diff")

Resume + a compact delta, then the usual `actions.instructions(current_open_members, batch.id)`:

```
This continues batch review #1 (round 3). Since the last round:
- RESOLVED (don't revisit): <id> file:line, …
- NEW comments to address: <id> file:line — "<first line>", …
- The user replied on these threads: <id> — "<their reply>", …
- Still open: <id>, <id>, …
Address every still-open / new comment as before; write .ai/review-actions-<batch.id>.json.
```

This + the session memory is enough; we never re-send the whole history in `diff` mode.

## 11. Composition drift (important)

The session remembers round-1 threads, but the set changes: resolved ones leave, new ones
join, lines move. **Every round must explicitly tell the agent which ids are new /
resolved / still-open** (see §10) so its memory doesn't act on stale or already-done
threads. `actions.instructions` should be passed only the *currently open* members.

## 12. UI for Option B (meta-thread)

- The sidebar list (`panel.lua build_list`) gets a Batch group at the top:
  `▣ Batch #1 · round 2 · 4 threads` with the member comments nested/badged.
- Opening the Batch renders a thread-like view: your round prompts + the agent's
  cross-thread narration (the streamed reply), with each member's resolution inline.
- Reply-to-all from there = `continue_batch(text)`.
- Reuses the existing chat surface (`build_chat`) with a "batch" source instead of a comment.

## 13. Edge cases / risks

- **Session expiry / not found.** Detect the `--resume` failure; fall back to `stateless`
  (re-serialize full state). Surface a quiet notice.
- **Concurrent resumes.** Don't let mode-3 per-thread replies fire while a `continue_batch`
  is in flight (serialize on `batch.dispatching`).
- **Agent skips a thread.** `actions.apply` already tolerates missing entries; after a round,
  flag any open member with no entry ("agent didn't address N threads") so the user can re-run.
- **Big batches.** Round-1 prompt can be large; `diff` keeps later rounds small. Consider a
  member cap with a `log()` notice if we ever truncate.
- **Mixing with per-thread chat.** A normal `<CR>` reply still uses the comment's own
  `session_id` (isolated). Only mode-3 routes into the batch session. Keep them distinct.

## 14. Phased plan

1. **Phase 1 — A (shared session + continue key). ✅ BUILT + review-hardened.** Batch record holding
   one session id; `<prefix>s` creates it; `<prefix>S`/`continue_batch` resumes with the diff; reuses
   `actions` + streaming. A 10-agent adversarial review fixed 6 bugs (clear_on_submit, stale-flag
   wedge, session fork, comment_ids pruning, silent save, seq collision).
1b. **Tagging. ✅ BUILT.** Sticky mode + manual tag/untag + tag-scoped submit (§4c).
2. **Parallel "dispatch all" — separate agent per thread. ⬅ NEXT.** Fan out each pending (or tagged)
   thread to its own streaming agent; reuses the same keyed `.ai/review-actions-<id>.json` mechanism
   (§4b, now built for every dispatch) so they triage in parallel without clobber. `<prefix>P`.
3. **Phase 2 — B (meta-thread object + UI).** The Batch list entry + meta-thread chat + reply-to-all;
   mode-3 reply-into-batch from a member thread.
4. **Phase 3 — switchable + polish.** `transport.batch.mode/object/prompt` config, the stateless
   fallback, composition-drift reporting, "agent skipped N" warnings.

## Code anchors (today)

- `init.lua` — `M.submit` (~L49), `do_respond`/resume (~L124–139).
- `transport/cli.lua` — `run_oneshot`, `base_cmd` `--resume` (~L36), session capture (~L168).
- `actions.lua` — `M.filename`/`M.path` (~L11), `M.instructions(comments, key)` (~L21),
  `M.apply(key, allowed)` (~L72), `M.sweep()` (stale keyed-file cleanup, called from setup()).
- `store.lua` — comments + `session_id`; the `Batch` record. Membership lives solely on
  `batch.comment_ids` — comments carry no batch back-ref.
- `config.lua` — `transport.cli.batch_model` (~L105); add `transport.batch`.
- `panel.lua` — `build_list` (the meta-thread entry), `build_chat` (the meta-thread view).
