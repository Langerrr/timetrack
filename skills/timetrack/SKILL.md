---
name: timetrack
description: Use when the user wants to log time they spent, change whether an agent run counts as paired or solo, or ask how much time went into a project. Triggers on "log two hours on X", "I spent the morning on Y", "track that meeting", "how much time on Z this week", "I'm heading out, let it run", "I'm back".
---

# timetrack

`tt` records per-project time. Run `tt help` for the full surface.

## Logging past work

The user states a project, a duration, and usually when. Resolve each before running anything.

1. **Project.** Match what they said against the directories under `~/workspace`
   (`ls ~/workspace`). "sportx", "the sportsx thing" and "SportX" all resolve to `sportx`.
   Ask when two directories match equally well.
2. **Duration.** Use what they stated. `90m`, `1.5h`, `2h30m` and a bare number of
   minutes all parse.
3. **When.** Convert their phrasing to `YYYY-MM-DD HH:MM` using the current
   timestamp you were given this turn. "Yesterday afternoon" becomes that date at
   `14:00`. `--at` is the *start* of the block and the duration runs forward from
   it, so a stated end time needs the duration subtracted first. Omit `--at` only
   when they mean the time just ending now.

Then run it and show the row:

    tt add sportx 2h "architecture review" --at '2026-09-01 14:00'

The note is a single argument and must be quoted. `tt add` treats every argument
that is not `--at` as the note and keeps only the last one, so
`tt add sportx 2h architecture review` silently records `review` and throws
`architecture` away. Quote the whole note, always.

`tt add` prints the row it wrote. Show that row back. Do not paraphrase it.

## Setting mode

`paired` means the user is working alongside the agent. `solo` means the agent is
running while they are elsewhere. Mode is held per session directory, so running
these from your own shell keys them to the right session automatically.

    tt solo      # "I'm heading out", "let it run", "going to lunch"
    tt paired    # "I'm back", "watching now"

Mode applies from that moment forward. It does not reach backwards over work
already recorded.

## Reporting

    tt report            # today
    tt report week
    tt report month
    tt report --since 2026-08-01 --until 2026-08-31
    tt report --by day
    tt report --detail   # break projects out by sub-directory

Read the table back in prose, leading with the number they asked for.

## Correcting a mistake

The log is a tab-separated file at `~/.timetrack/events-<machine>.tsv`, eleven
columns: `iso_start, kind, start, end, machine, harness, mode, project, subpath,
session, note`. Rows with kind `span` are manual entries and may be edited or
deleted. Rows with kind `beat` are captured evidence: leave them as written.

## Rules

- Log only a duration the user stated or confirmed. Never estimate one from how
  long a conversation ran.
- Time coming up in conversation is conversation. Log when asked to log.
- Always show the written row.
- One `tt add` per distinct block of work. Do not batch several into one row.
