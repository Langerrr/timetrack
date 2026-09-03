---
name: timetrack
description: Use when the user wants to log time they spent, change whether an agent run counts as paired or solo, or ask how much time went into a project. Triggers on "log two hours on X", "I spent the morning on Y", "track that meeting", "how much time on Z this week", "I'm heading out, let it run", "I'm back".
---

# timetrack

`tt` records per-project time. Resolve `scripts/tt` relative to this `SKILL.md`
and invoke it with `sh`; do not assume bare `tt` is on `PATH`. In the examples
below, `$TT_CMD` is that absolute script path. Run `sh "$TT_CMD" help` for the
full surface.

## Logging past work

The user states a project, a duration, and usually when. Resolve each before running anything.

1. **Project.** Read the configured project root with `sh "$TT_CMD" root`, then
   match what they said against the directories immediately under that path.
   "sportx", "the sportsx thing" and "SportX" all resolve to `sportx`.
   Ask when two directories match equally well, and ask when **none** does: `tt add`
   accepts any string as PROJECT, so a name you guessed at creates a project that
   is indistinguishable from a real one in every report afterwards. Say which
   directory you could not find a match for, and let the user name it.
2. **Duration.** Use what they stated. `90m`, `1.5h`, `2h30m` and a bare number of
   minutes all parse.
3. **When.** Convert their phrasing to `YYYY-MM-DD HH:MM` using the current
   timestamp you were given this turn. "Yesterday afternoon" becomes that date at
   `14:00`. `--at` is the *start* of the block and the duration runs forward from
   it, so a stated end time needs the duration subtracted first. Omit `--at` only
   when they mean the time just ending now.

Then run it and show the row:

    sh "$TT_CMD" add sportx 2h "architecture review" --at '2026-09-01 14:00'

The note is a single argument and must be quoted. `tt add` treats every argument
that is not `--at` as the note and keeps only the last one, so
`tt add sportx 2h architecture review` silently records `review` and throws
`architecture` away. Quote the whole note, always.

`tt add` prints the row it wrote. Show that row back. Do not paraphrase it.

## Setting mode

`paired` means the user is working alongside the agent. `solo` means the agent is
running while they are elsewhere. Mode is held per session directory, so running
these from your own shell keys them to the right session automatically.

    sh "$TT_CMD" solo      # "I'm heading out", "let it run", "going to lunch"
    sh "$TT_CMD" paired    # "I'm back", "watching now"

Mode applies from that moment forward. It does not reach backwards over work
already recorded. Submitting a prompt returns that directory to paired on both
harnesses, because a prompt means the user is back. Setting solo and *then*
sending the instruction that starts the unattended run therefore cancels itself:
set solo during the turn that is already running, not before it.

## Reporting

    sh "$TT_CMD" report            # today
    sh "$TT_CMD" report week
    sh "$TT_CMD" report month
    sh "$TT_CMD" report --since 2026-08-01 --until 2026-08-31
    sh "$TT_CMD" report --by day
    sh "$TT_CMD" report --detail   # break projects out by sub-directory

Read the table back in prose, leading with the number they asked for. `ESTIMATED`
is the portion of `PAIRED` inferred as reading time after a solo response; it is
a disclosed subset and must not be added to `TOTAL` again.

## Correcting a mistake

The log is a tab-separated file at `~/.timetrack/events-<machine>.tsv`. Manual
`span` rows retain the original eleven columns. New `beat` rows append
`turn_id, tool_use_id, agent_id, agent_type, assistant_words` as columns 12–16;
old eleven-column beats remain valid. Column 11 holds the user's note on a span
and the hook event name (`SessionStart`, `PreToolUse`, …) on a beat, so never
read it back as something the user wrote. `assistant_words` is a count; raw
assistant output is never stored. Span rows may be edited or deleted. Beat rows
are captured evidence: leave them as written.

## Rules

- Manually log only a duration the user stated or confirmed. Do not invent a
  manual entry from conversation length; the reporter owns its explicit,
  bounded solo-reading estimate.
- Time coming up in conversation is conversation. Log when asked to log.
- Always show the written row.
- One `tt add` per distinct block of work. Do not batch several into one row.
