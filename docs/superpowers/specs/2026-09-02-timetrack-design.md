# timetrack — design

Date: 2026-09-02

## Purpose

Record how much time goes into each project under `~/workspace`, across several
machines and several agent harnesses, keeping three kinds of time apart: time
worked alongside an agent, time an agent worked alone, and time spent away from
any agent at all.

## Constraints

- Runtime is POSIX `sh`, `awk`, `sed` and `date`. Nothing else is assumed present.
- Runs on Ubuntu under WSL2 and on macOS.
- Serves Claude Code and Codex today, and any harness with a hook mechanism later.
- No graphical interface. Output is aligned plain text.

## Data model

### Current detail and compact totals

Each machine uses two TSV files. `current-<machine>.tsv` holds detailed rows for
the current local day. Each detail row is one event, of one of three kinds:

- `beat` — emitted by a harness hook. `start` equals `end`.
- `mode` — emitted by `tt solo` or `tt paired`. `start` equals `end`.
- `span` — a manual entry. `start` and `end` bound a stated duration.

Columns, in order:

| # | Column | Meaning |
|---|--------|---------|
| 1 | `iso_start` | Local time, formatted at capture |
| 2 | `kind` | `beat`, `mode` or `span` |
| 3 | `start` | Epoch seconds |
| 4 | `end` | Epoch seconds |
| 5 | `machine` | Machine identity |
| 6 | `harness` | `claude`, `codex`, … or `-` for spans |
| 7 | `mode` | `paired`, `solo` or `manual` |
| 8 | `project` | Top-level directory under the workspace root |
| 9 | `subpath` | Remainder of the event's working directory |
| 10 | `session` | Harness session id, or `-` |
| 11 | `note` | Free text, or `-` |

New beat rows append optional lifecycle fields while the first eleven columns
remain stable:

| # | Column | Meaning |
|---|--------|---------|
| 12 | `turn_id` | Turn identifier — Codex `turn_id`, Claude Code `prompt_id` — or `-` |
| 13 | `tool_use_id` | Tool-call identifier, or `-` |
| 14 | `agent_id` | Subagent identifier, or `-` |
| 15 | `agent_type` | Subagent type or profile, or `-` |
| 16 | `assistant_words` | Final assistant-message word count on `Stop`, or `-` |
| 17 | `session_source` | `SessionStart` source, or `-` |

Manual spans may remain eleven columns. Raw assistant-message content is never
persisted.

`events-<machine>.tsv` is the compact history. Its first row has kind `compact`
and stores the active local-day boundary. Completed days use kind `total`, with
the day boundaries in columns 3–4, mode/project/subpath in columns 7–9, seconds
in column 11, and the estimated-reading subset in column 12. There is at most
one total per day, project, subpath, and mode after a normal rollover.

At the first write or report after midnight, completed detail is reconstructed
and replaced by totals. Only today's detail and small internal `state` rows
needed to continue an interval across midnight remain in the current file. A
legacy single-file event log migrates through the same operation.

Each row carries epoch seconds and a preformatted local timestamp written at
capture time. Reporting therefore compares and sums integers, and behaves
identically on both operating systems.

### Attribution

`project` and `subpath` derive from `cwd` on each hook or mode event. A harness
session remains one activity timeline when its cwd changes; subpaths attribute
sequential pieces and never create concurrent copies of that session.

- Session directory under `TT_ROOT` (default `~/workspace`): `project` is the
  first path segment, `subpath` is the remainder, or `.` at the project root.
- Session directory at `TT_ROOT` itself: `project` is `~root` and `subpath` is `.`.
- Session directory anywhere else: `project` is `~outside` and `subpath` is the
  absolute path.

### Mode

`paired` and `solo` are set by hand and apply to agent time. `manual` belongs to
spans, and marks time that involved no agent.

The explicit `mode` event in the current detail log is the reporting source of
truth. It splits matching active intervals at its exact timestamp. The
`~/.timetrack/modes` file is a capture-time cache with one
`mode<TAB>absolute-path<TAB>session` row per scope; `session` is `-` for all
sessions. A row covers its path and descendants, and rows are ordered by their
last explicit transition so the latest matching scope wins. The cache is
rewritten whole under a lock. A path with no matching row reads as `paired`.
Paths or session ids containing the file's TAB/newline separators are refused.

    tt solo [path] [--session id|--all-sessions]      # path defaults to $PWD
    tt paired [path] [--session id|--all-sessions]
    tt sessions         # every explicit path/session scope and its mode

An in-session command uses the harness session id from its environment when one
is available. An external terminal has no such id and affects every session
whose current attribution is inside the path subtree. `--session` and
`--all-sessions` override either default. Session scope disambiguates two
sessions at one path.

Each beat is stamped from the cache, but the durable mode event supplies the
exact boundary. Mode remains sticky until another explicit command changes it.
Only overlap with reconstructed agent activity is classified; a solo window
does not itself create tracked duration.

`UserPromptSubmit` never changes mode. Forked or subagent sessions can emit it,
so it is not reliable evidence that the human returned. Codex also exposes no
scroll, focus, composer or typing-start hook; `tt paired` is the signal.

After a solo `Stop`, timetrack can estimate reading from the final output size
when the user next submits a prompt in paired mode. The estimate is placed
immediately before that prompt, clipped to the explicitly paired portion, and is:

    min(assistant_words * 60 / TT_READING_WPM,
        actual Stop-to-prompt gap,
        TT_MAX_READING_TIME)

`TT_READING_WPM` defaults to 120 and is a personal, configurable assumption for
careful non-native reading. `TT_MAX_READING_TIME` defaults to 600 seconds. The
remainder of the solo gap is not counted. Estimated reading is paired time and
is also disclosed as a non-additive `ESTIMATED` subset in reports.

### Reconstructing intervals

Beats group by machine, harness and session, sorted by start. Rows without a
usable session id retain project/subpath in their fallback key to avoid joining
unrelated malformed streams.
Append order is the numeric tie-breaker for equal-second events. A complete
`UserPromptSubmit` to `Stop`/`Interrupt` turn counts regardless of
`TT_IDLE_GAP`; matched tool and subagent lifecycle pairs fill the same gap when
a main-turn boundary is absent. Subagent activity shares
the parent stream and is not added again when it overlaps the parent turn.

Because known activity ignores `TT_IDLE_GAP`, an ending that was never recorded
would otherwise count the whole absence that follows it, and no harness
guarantees an event for every ending — Claude Code records nothing when the user
interrupts. Three rules bound this. A single gap inside an open turn, tool call
or subagent run counts at most `TT_MAX_ACTIVE_GAP` (3600 seconds by default),
counted forward from the beat that marked the activity, so a genuinely long tool
call keeps that much of its length rather than being discarded; `0` removes the
ceiling. A `UserPromptSubmit` carrying a turn identifier other than the one
still open closes that turn, because a new prompt shows the previous one ended.
A `SessionStart` arriving mid-stream closes everything open when its source is
`startup`, `resume`, or `clear`, because a resumed session keeps its id and
rejoins its own stream. Codex also emits `SessionStart` with `source=compact`
during an active turn; that continuation preserves the open lifecycle state.

For legacy and incomplete rows, two consecutive beats no more than
`TT_IDLE_GAP` apart (default 900 seconds) contribute their difference, assigned
to the earlier beat's mode. A paired `Stop` to a timely next prompt also uses
this rule. A solo `Stop` never contributes the whole return gap; only its bounded
reading estimate can contribute. Independent top-level sessions remain
additive.

Beats rather than start/stop pairs mean a killed terminal or a crashed harness
costs the tail of one block and leaves no unterminated interval behind.

Intervals and spans are reconstructed before applying the report range. Ranges
are half-open and each interval is clipped to `[since, until)`. `--until D`
means the first real instant after local date D, including D's final minute.
`--by day` splits intervals at real local-day boundaries, including DST days
that do not begin at 00:00. Spans contribute their clipped `end - start`.

## Storage

    ~/.timetrack/
      config              # machine= and TT_* preferences
      events-<machine>.tsv  # tracked completed-day totals
      current-<machine>.tsv # gitignored current-day detail and carry state
      modes               # mode<TAB>absolute-path<TAB>session capture cache

A private git repository for the compact files. Current detail, modes, and lock
directories are gitignored. Each machine writes only its own pair of files, so
pulls and pushes touch disjoint paths.

Machine identity comes from `machine=` in `config`, falling back to the short
hostname. Setting it explicitly keeps a renamed machine writing to the same file.

## Command surface

    tt hook                        # read hook JSON on stdin, append one beat
    tt add <project> <duration> [note] [--at 'YYYY-MM-DD HH:MM']
    tt solo|paired [path] [--session id|--all-sessions]
    tt sessions
    tt root
    tt report [today|yesterday|week|month] [--since D] [--until D] [--by project|day] [--detail]
    tt sync pull <host>
    tt install-remote <host>
    tt hooks-snippet [claude|codex]

Durations parse as `90m`, `1.5h` or `2h30m`. `tt add` without `--at` ends the
span at the current time. `tt add` prints the row it wrote.

`tt report` covers today unless given a period. `yesterday` is the complete
previous local day; `week` and `month` are week-to-date and month-to-date. Its
periods and flags are listed by both `tt report --help` and `tt help report`.

`tt report` prints one row per project with paired, solo, manual, estimated and
total columns. Estimated is a subset of paired, not another additive mode.
`--detail` breaks projects out by subpath. Buckets below the display's
one-minute resolution are omitted rather than rendered as all-zero rows.

Automatic rollover keeps storage proportional to the number of daily
project/mode totals plus at most one local day's detailed hook traffic. The
compact file also holds the active-day marker, so an ordinary hook checks for a
rollover without scanning the current file. Rewrites and appends share a
per-machine POSIX `mkdir` lock. Reconstruction preferences are applied at
rollover; a later configuration change does not reinterpret completed totals.
Source and generated rows are validated before either file is replaced, so a
mismatched or interrupted plugin upgrade fails closed without discarding the
recoverable input.

## Hook capture

Every event that opens or closes tracked activity is wired on both harnesses.

Claude Code fires `SessionStart`, `UserPromptSubmit`, `PreToolUse`,
`PostToolUse`, `PostToolUseFailure`, `PermissionDenied`, `SubagentStart`,
`SubagentStop`, `Stop`, `StopFailure` and `SessionEnd`. `PostToolUse` fires only
when a tool call succeeds: a failed call ends at `PostToolUseFailure` and a
denied one at `PermissionDenied`, and a turn ending in an API error ends at
`StopFailure` rather than `Stop`. Codex fires `SessionStart`,
`UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, `Interrupt`,
`SessionEnd`, `SubagentStart` and `SubagentStop`. Each calls `tt hook`, which reads
`session_id`, `cwd` and available lifecycle identifiers from stdin with a POSIX
awk scanner, falls back to `$PWD` when the path is absent, appends one line and
exits. On `Stop`, it reduces `last_assistant_message` to a word count in memory
and never writes the message.

Installing the plugin wires these hooks. `tt hooks-snippet` prints the equivalent
configuration for a machine set up by hand.

## Packaging

A plugin repository, `Langerrr/timetrack`, cloned to
`~/workspace/langerrr/timetrack` and listed in the `langerrr` marketplace
manifest beside `zforge` and `distributed-architect`.

    timetrack/
      .claude-plugin/plugin.json
      .codex-plugin/plugin.json
      bin/tt
      hooks/hooks.json
      hooks/codex-hooks.json
      skills/timetrack/SKILL.md
      skills/timetrack/scripts/tt
      README.md

Dual manifests serve Claude Code and Codex from one source tree, following the
layout `zforge` already uses. Installing the plugin wires the hooks. The skill's
bundled wrapper resolves `bin/tt` from the installed plugin root, so agent-driven
commands need no PATH link. A symlink remains optional for direct shell use.

The event log lives outside this repository. The tool is generic and shareable;
the log is personal, and separating them leaves the plugin repository's
visibility a free choice.

## Skill

`skills/timetrack/SKILL.md`, loaded by both harnesses, covering four jobs:

**Logging past work.** From "two hours on sportx yesterday afternoon for the
architecture review", read `TT_ROOT` through `tt root`, resolve `sportx` against
the directories beneath it, convert the relative time to a concrete `--at`
argument using the current
timestamp, run `tt add`, and show the row that was written.

**Setting mode.** "I'm heading out, let it run" runs `tt solo`; "I'm back" runs
`tt paired`. The current path covers its subtree. When the user identifies one
of several sessions, pass `--session`; never infer return from a prompt.

**Reporting.** Run `tt report` for the period asked about and read the table back.

**Correcting.** The log is plain TSV with a documented schema. A current-day
`span` may be edited directly; after rollover, correct the matching compact
`total` row instead. Beat detail is discarded when its day closes.

Guardrails: log only a duration the user stated or confirmed, treat time coming
up in conversation as conversation, and always echo the written row.

## The mac-mini

The mac-mini runs no git and holds no credentials. Both directions cross
Tailscale SSH, initiated from a trusted machine.

`tt install-remote macmini` connects over SSH, clones or fast-forwards the public
plugin repository, writes `machine=macmini`, and prints the local-marketplace
registration commands for that host.

`tt sync pull macmini` copies both `events-macmini.tsv` and
`current-macmini.tsv` to the trusted machine. Only the compact file is committed
and pushed. One machine owns each pair, so the pulls are whole-file overwrites
and repeat harmlessly. An offline mac-mini fails the pull and keeps its data
until the next one.

## Out of scope

A live stopwatch, editing beats, CSV export, a background daemon, OS-level idle
or input monitoring, and exact measurement of pre-submit reading or typing.

## Codex integration status

Codex CLI 0.152.1 accepts the manifest's explicit hooks path and exports
`PLUGIN_ROOT` to plugin hook commands. Its hooks require interactive review and
trust; a changed hook definition must be reviewed again after reinstalling the
plugin.
