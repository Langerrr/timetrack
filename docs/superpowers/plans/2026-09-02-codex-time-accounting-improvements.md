# Codex Time Tracking Improvement Plan

**Status:** Implemented and reverified on Linux on 2026-09-03 after adding the
Codex compaction-continuation case. The automated suite, skill validation,
Claude manifest validation, and a temporary Codex plugin installation pass. A
macOS run and an interactive Codex hook-trust smoke test remain
environment-dependent follow-up checks.

**Goal:** Keep timetrack's append-only, dependency-free design while making its
reported time match Codex's actual turn and tool lifecycle, preserving correct
paired/solo attribution across long runs, user returns, date boundaries,
interruptions, subagents, and bounded reading-time estimates after solo runs.

**Architecture:** Hooks remain evidence capture and never hold an open timer.
New beat rows append Codex lifecycle identifiers after the existing eleven TSV
columns. Reporting becomes event-aware: complete turns and tool calls establish
known-active intervals, while the existing idle-gap heuristic is retained only
where Codex cannot prove activity. A solo `Stop` may also carry only the word
count of its final assistant message, allowing reporting to reconstruct a
clearly identified, bounded reading-time estimate when the user next submits a
prompt. Existing eleven-column logs remain readable.

**Constraints:** Runtime stays POSIX `sh`, `awk`, `sed`, and base Unix tools; no
daemon, database, `jq`, Python, or platform UI instrumentation. Hooks must stay
non-blocking from the user's perspective and must never break a Codex or Claude
Code session.

## Agreed tracking semantics

1. `UserPromptSubmit` is the earliest supported proof that the user has
   returned. If the session directory is currently `solo`, that event
   automatically changes it to `paired` at the submission timestamp. The
   submitted turn is therefore paired unless the user explicitly switches it
   back to solo, including with a prompt such as "continue and let it run
   solo."
2. Codex exposes no hook for window focus, scrolling history, focusing the
   composer, or starting to type. Time before `UserPromptSubmit` therefore
   cannot be measured exactly by a portable plugin. After a solo run, timetrack
   may estimate reading time from the final assistant-message word count as
   described below, but must identify it as estimated rather than observed.
   OS-level input monitoring and arbitrary fixed lookback windows are out of
   scope because they would be platform-specific, privacy-sensitive, and
   inaccurate.
3. A completed `UserPromptSubmit` to `Stop` or `Interrupt` turn is known agent
   activity and counts even when it is longer than `TT_IDLE_GAP`.
4. After a paired `Stop`, the gap to the next `UserPromptSubmit` counts as paired
   work when it is no longer than `TT_IDLE_GAP`; this represents reading,
   reviewing, thinking, and composing the next prompt. A larger gap opens a new
   block so an idle terminal does not count overnight inactivity.
5. After a solo `Stop`, most of the gap to the next `UserPromptSubmit` remains
   uncounted. When `last_assistant_message` is available, the `Stop` hook stores
   only its word count. At the next user prompt, timetrack adds an estimated
   reading interval immediately before the prompt, calculated as:

   `min(output_words * 60 / TT_READING_WPM, actual_stop_to_prompt_gap,
   TT_MAX_READING_TIME)`

   The default `TT_READING_WPM` is **120 words per minute**, chosen as a
   conservative personal default for careful reading by a non-native English
   speaker; it is a configurable preference, not a claim about every reader.
   The default `TT_MAX_READING_TIME` is **600 seconds**. Fractional results are
   rounded deterministically to whole seconds. The rest of the solo gap remains
   uncounted, and the prompt submission changes the directory to paired as
   described above. If the message or word count is unavailable, no reading
   time is invented.
6. Explicit `tt solo` and `tt paired` changes continue to apply forward from the
   event that observes them. Mode changes inside a turn split that turn.
7. Independent top-level sessions retain the current additive behavior. Work by
   subagents is folded into the parent turn and does not double-count time merely
   because parent and child activity overlap.

## Review findings to address

### 1. Report boundaries discard overlapping time

`lib/report.awk` filters rows by their start timestamp before reconstructing an
interval. A beat immediately before midnight and one immediately after midnight
form a valid interval in a broad report, but neither daily report receives its
half. Manual spans beginning before the range are omitted, while spans beginning
inside and ending after it are over-counted. `--until` is also represented as
`23:59:00`, dropping the final 59 seconds of the selected date.

Observed reproduction: beats at 23:59 and 00:01 report as two minutes across
both days but zero minutes for the second day instead of one.

### 2. Long known-active Codex operations are treated as idle

All adjacent beat gaps longer than `TT_IDLE_GAP` are discarded. Codex
`PreToolUse` and `PostToolUse` events bracket a real operation, including a
long-running unified shell command, yet a command lasting more than fifteen
minutes currently contributes zero. A complete long turn can be lost for the
same reason. The hook payload exposes `turn_id` and `tool_use_id`, but timetrack
does not retain them.

### 3. Equal-second events can reverse a mode transition

Beat timestamps have one-second precision. `sort -k 3,3n` applies a lexical
tie-breaker instead of preserving append order, so a fast `solo` to `paired`
change can place `PostToolUse` before `PreToolUse`. The following interval is
then assigned to solo.

Observed reproduction: a same-second solo-to-paired transition followed by a
one-minute paired interval reports the minute as solo.

### 4. Codex lifecycle coverage is incomplete

The shared hook file records `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PostToolUse`, and `Stop`, but not `Interrupt`, `SessionEnd`, `SubagentStart`, or
`SubagentStop`. Missing those boundaries loses evidence around interrupted and
autonomous work. Codex subagent events use the parent session id, so they need
their own agent identifiers and must not be summed as independent sessions.

### 5. The Codex skill assumes `tt` is on `PATH`

Codex loads the skill and the automatic plugin hooks work, but an installed
plugin's root executable is not currently discoverable as bare `tt` in the
agent shell. Natural-language logging, reporting, and mode changes therefore
fail unless the user also creates the documented symlink.

### 6. The skill ignores configured `TT_ROOT`

Project resolution is hardcoded to `~/workspace` even though the CLI supports a
different root in `~/.timetrack/config`. This can reject a real project or
create a phantom project name on a valid non-default installation.

## Data format evolution

Keep columns 1 through 11 unchanged and append these optional fields to new beat
rows:

| # | Field | Meaning |
|---|---|---|
| 12 | `turn_id` | Codex turn identifier, or `-` when unavailable |
| 13 | `tool_use_id` | Codex tool-call identifier, or `-` |
| 14 | `agent_id` | Codex subagent identifier, or `-` |
| 15 | `agent_type` | Codex subagent type/profile, or `-` |
| 16 | `assistant_words` | Word count of `last_assistant_message` on `Stop`, or `-` |
| 17 | `session_source` | `SessionStart` source, or `-` |

Manual spans may remain eleven columns or write `-` in all extension columns;
the implementation should choose one canonical output and test both readers.
Reports must accept old eleven-column rows, mixed old/new files, and new rows
without migration. Claude Code payloads that do not provide the extension
fields write `-` and use event-order inference. Raw assistant-message content
must never be written to the event log.

## Implementation tasks

### Task 1: Lock the semantics down with failing tests

**Files:** `tests/run.sh`, optionally new fixture files under `tests/fixtures/`.

- Add a crossing-midnight beat interval and assert that each daily range gets
  only its overlapping portion.
- Add manual spans crossing the lower and upper report bounds and assert clipped
  durations.
- Assert that `--until YYYY-MM-DD` includes the entire named local day.
- Add a same-second `PreToolUse`/`PostToolUse` mode transition and assert append
  order wins.
- Add a turn and a matched tool call longer than `TT_IDLE_GAP`; both must count.
- Assert a paired `Stop` to prompt gap counts within `TT_IDLE_GAP` and is dropped
  beyond it.
- Assert a solo `Stop` to prompt gap is always dropped, while the submitted turn
  changes to and reports as paired when no reading estimate is available.
- Add solo-return fixtures for short and long assistant outputs. Assert the
  estimate uses 120 words per minute by default, can be configured, is capped by
  both the actual stop-to-prompt gap and `TT_MAX_READING_TIME`, occupies the
  interval immediately before the prompt, and never double-counts paired or
  observed time.
- Assert missing/null assistant output produces no estimate, raw output is not
  persisted, estimates clip correctly at report/day boundaries, and reports
  retain enough provenance to distinguish estimated reading time from observed
  and manual time.
- Assert explicit mode changes split one long turn at the observed beat.
- Add `Interrupt`, `SessionEnd`, and subagent fixtures; assert terminal tails are
  bounded and subagent overlap is counted once.
- Run equivalent report cases using old eleven-column rows, new extended rows,
  and a mixed log.

### Task 2: Capture complete Codex lifecycle evidence

**Files:** `bin/tt`, `hooks/hooks.json`, new `hooks/codex-hooks.json`,
`.codex-plugin/plugin.json`, tests.

- Extend the top-level JSON string reader usage to capture `turn_id`,
  `tool_use_id`, `agent_id`, `agent_type`, and the `SessionStart` source when
  present. On `Stop`, count the words in `last_assistant_message` without
  persisting the message itself.
- Append the optional fields without altering the meaning or order of the first
  eleven columns.
- Preserve the current single-append write and field-cleaning limits.
- Keep `hooks/hooks.json` compatible with Claude Code. Add a Codex-specific hook
  file containing the common events plus `Interrupt`, `SessionEnd`,
  `SubagentStart`, and `SubagentStop`, and select it from the Codex manifest.
- Keep hooks synchronous: mode capture and append order are semantic inputs, and
  asynchronous hooks may finish out of order.
- Document that changing the Codex hook definition changes its trust hash and
  requires review through `/hooks` after the plugin update.

### Task 3: Make reporting event-aware and range-correct

**Files:** `bin/tt`, `lib/report.awk`, tests.

- Change report ranges to half-open intervals: `[since, until)`. For an explicit
  `--until`, compute the first real instant of the following local day using the
  existing cross-DST date helpers rather than assuming every day is 86,400
  seconds.
- Feed all potentially relevant rows to reconstruction. Construct intervals
  first, then clip each interval or span to the requested range.
- Split intervals at local day boundaries for `--by day`; never assign an entire
  crossing interval to its starting date.
- Use stable numeric sorting so equal-second rows from one machine preserve
  append order. Keep machine/session grouping so equal timestamps from unrelated
  logs cannot affect one another.
- Track active main turns by `turn_id`, ending them at `Stop` or `Interrupt`.
  Count the full known-active interval regardless of the idle threshold and
  subdivide it at observed mode changes.
- Match known tool activity by `tool_use_id` as recovery evidence, especially
  when a turn lacks its terminal event. Do not double-count tool intervals that
  already sit inside a complete turn.
- Use `SessionEnd` as a final closing boundary when appropriate. Preserve the
  crash-safe rule that an unmatched final start does not extend to report time.
- Treat Codex `SessionStart(source=compact)` as a continuation of the current
  turn; other session-start sources reset stale lifecycle state.
- Treat subagent activity as part of its parent turn. Use `agent_id` only to
  recover its observed boundaries, not to add overlapping agent-hours.
- Retain the beat-gap heuristic for legacy rows and genuinely unknown intervals,
  with the paired/solo between-turn policy defined above.
- When a prompt follows a solo `Stop` with `assistant_words`, synthesize the
  bounded reading interval defined above. Mark its provenance as estimated in
  detailed output while including it in the paired total. Place the estimate
  immediately before the prompt so range clipping and daily grouping remain
  deterministic; never extend it before the recorded `Stop`.

### Task 4: Make user return and solo reading estimates explicit

**Files:** `bin/tt`, tests, documentation.

- On `UserPromptSubmit`, atomically change a solo directory to paired before
  writing the beat, reusing the existing modes-file lock and quieting normal
  command output in hook context.
- Before changing modes, use the most recent eligible solo `Stop` to derive the
  bounded reading estimate. Treat this as a separate estimated paired interval,
  not as a retroactive mode change for the rest of the solo gap.
- Add `TT_READING_WPM` with a default of 120 and `TT_MAX_READING_TIME` with a
  default of 600 seconds. Validate both as positive numeric configuration and
  fall back safely when invalid.
- Ensure the prompt event and later events in that turn carry paired mode unless
  an explicit `tt solo` changes it again.
- Cover simultaneous prompt and manual mode writes with concurrency tests.
- Explain that pre-submit scrolling and typing cannot be observed. Present the
  output-size calculation as a reading estimate and expose its assumptions in
  detailed reports.

### Task 5: Make the skill self-contained in Codex

**Files:** `skills/timetrack/SKILL.md`, new
`skills/timetrack/scripts/tt`, `bin/tt`, tests.

- Add a small POSIX wrapper under the skill directory that resolves the plugin
  root relative to itself and executes `bin/tt`.
- In the skill, use that bundled command when bare `tt` is unavailable so a
  plugin installation is sufficient for agent-driven actions.
- Add a public, read-only command that prints the effective configured project
  root; use it instead of hardcoded `~/workspace` during project resolution.
- Preserve the current requirement to confirm ambiguous or missing project
  matches and to echo every written manual row.
- Test the wrapper from a copied/versioned plugin-cache-shaped directory with no
  `tt` on `PATH`.

### Task 6: Documentation, compatibility, and verification

**Files:** `README.md`,
`docs/superpowers/specs/2026-09-02-timetrack-design.md`, manifests, tests.

- Update the data model, event-aware interval rules, exact paired/solo return
  semantics, solo reading estimate and configuration, supported Codex events,
  and the UI-activity limitation.
- Explain that plugin updates containing hook changes require renewed trust.
- State explicitly that independent top-level sessions add, while subagent work
  inside a parent turn is counted once.
- Reconcile install instructions so PATH setup is optional for human shell use
  and unnecessary for the installed skill.
- Bump the plugin version because installed plugins are cached by version.
- Run `sh tests/run.sh` on Linux and a POSIX-shell/macOS environment when
  available.
- Reinstall the plugin into a temporary Codex home, review/trust the hooks, run a
  real interactive fixture, and verify captured event names, extended fields,
  automatic return-to-paired behavior, a long command, interruption, and the
  final report.

## Acceptance criteria

- Existing logs and manual entries continue to report without migration.
- A complete Codex turn longer than `TT_IDLE_GAP` is fully counted.
- Paired review/composition time between a stop and timely next prompt counts;
  solo idle time after a stop does not, except for the bounded reading estimate
  derived from the final assistant output when the user returns.
- The first submitted prompt after solo is paired from its submission timestamp,
  and any pre-submit time added from the solo run is visibly estimated,
  bounded by the actual gap and configured cap, and based on 120 words per
  minute by default.
- No raw assistant output is persisted, and a missing output produces zero
  estimated reading time.
- Cross-boundary reports conserve time: the sum of adjacent daily reports equals
  the corresponding combined range, subject only to displayed minute rounding.
- Same-second mode transitions are deterministic and forward-only.
- Interrupts and subagents leave enough evidence for bounded, non-duplicated
  reconstruction.
- Agent-driven logging and reporting work in Codex without a PATH symlink and
  honor configured `TT_ROOT`.
- Hook failures still cannot block or fail a Codex/Claude Code session.

## Source note

The current official Codex hook reference lists lifecycle events and payload
fields such as `UserPromptSubmit`, `Stop`, `Interrupt`, `turn_id`,
`tool_use_id`, subagent identifiers, and `last_assistant_message` on `Stop`. It
exposes no focus, scroll, or typing-start event:
<https://learn.chatgpt.com/docs/hooks>.

## Verification result

- The complete shell test suite passes, including legacy/mixed log formats,
  lifecycle reconstruction, same-second ordering, range clipping, solo return,
  reading estimates, the bundled skill wrapper, and hook failure containment.
- The current Codex CLI accepts and installs the version 0.3.1 manifest with its
  explicit `hooks/codex-hooks.json` path in a temporary Codex home.
- The skill validator and Claude plugin validator pass. The older standalone
  plugin validator bundled with the local plugin-creation tooling rejects the
  manifest's `hooks` field, but that conflicts with both the current Codex CLI
  behavior and Codex's current plugin-packaging documentation.
- macOS behavior and the interactive re-trust prompt cannot be exercised in
  this Linux, non-interactive environment and remain explicitly unverified.
