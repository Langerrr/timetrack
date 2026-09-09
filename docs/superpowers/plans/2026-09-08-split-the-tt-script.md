# Split the tt script

> **Status: completed.** Tasks 1–2, including the standalone-loader correction are implemented and reviewed. See the [completion record](../reports/2026-09-08-completion.md) for commits, verification, decisions, and the subsequent authorized cleanup. The steps and code snippets below are the historical implementation recipe; unchecked recipe boxes do not indicate remaining work.

> **For agentic workers:** this is a code move, not a redesign. The invariant below is the whole acceptance criterion.

**Goal:** Give the hook its own entry point, so a hook fire loads the code it needs instead of the whole CLI.

**Architecture:** Three shell files where there is one. `lib/tt-common.sh` holds what both need, `bin/tt-hook` is the hook entry point, `bin/tt` is the human CLI. Reporting and compaction already dispatch to Python and are untouched.

**Tech Stack:** POSIX `sh`, runnable under `dash`. No Python changes.

**Spec:** none — this plan carries its own requirements. It follows `docs/superpowers/specs/2026-09-08-effort-and-machine-time-design.md`, which is unaffected.

## Global Constraints

- **Behaviour is identical before and after.** No logic changes, no schema changes, no new columns, no renamed variables in the log.
- Both suites give the same results after as before: `PYTHONPATH=lib python3 -m unittest discover -s tests/python`, `sh tests/run.sh`, `dash tests/run.sh`. Same counts, same names.
- POSIX `sh` only. No bashisms. Must run under `dash`.
- A hook must still never fail its harness: every path tolerates a missing or read-only `$TT_HOME`.
- The on-disk formats — the TSV, the mode files, the lock directory — do not change by a byte.

## Why

`bin/tt` is 1351 lines. The hook path is 305 of them, so every hook fire — 360 of them in a working day — parses 1046 lines it never calls. Splitting also gives the hook a test surface of its own instead of one shared with the CLI.

## File Structure

**Created:**

- `lib/tt-common.sh` — helpers both entry points call: `tt_home`, `tt_root`, `tt_config`, `tt_now`, `tt_iso`, `tt_machine`, `tt_clean`, `tt_attribute`, `tt_append_row`, `tt_write_mode_row`, `tt_event_lock` and whatever else both sides prove to need. Sourced, never executed.
- `bin/tt-hook` — the hook entry point: `cmd_hook`'s body plus the helpers only it calls (`tt_json_str`, `tt_word_count`, `tt_fingerprint`, `tt_solo_commands`, `tt_trigger_file`, `tt_classify_prompt`, `tt_mode`, `tt_cache_mode`).

**Modified:**

- `bin/tt` — sources `lib/tt-common.sh`; loses the hook path. `tt hook` remains as a thin forwarder to `bin/tt-hook` so any hook config still pointing at it keeps working.
- `hooks/hooks.json`, `hooks/codex-hooks.json` — every entry calls `bin/tt-hook` directly.
- `tests/run.sh` — hook assertions drive `bin/tt-hook`; the rest is untouched.
- `README.md` — the install snippets and the file list.

---

### Task 1: Extract the shared helpers

**Files:**
- Create: `lib/tt-common.sh`
- Modify: `bin/tt`
- Test: `tests/run.sh`

- [ ] **Step 1: Record the baseline**

Run all three suites and save the exact counts and, for the shell suite, the assertion names. This is what "identical" is measured against.

- [ ] **Step 2: Move the shared helpers**

Move — do not rewrite — each helper both entry points need into `lib/tt-common.sh`. Keep the bodies byte-identical apart from indentation. The file sets no variables on load beyond defaults already set at the top of `bin/tt`, and it must be safe to source twice.

- [ ] **Step 3: Source it from `bin/tt`**

`bin/tt` sources `lib/tt-common.sh` relative to its own location, using the existing `tt_self` mechanism, honouring `TT_LIB` the way the report path already does.

- [ ] **Step 4: Verify identical**

All three suites, same counts and names as Step 1. Any difference is a defect in the move.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "Extract the helpers both entry points share"
```

---

### Task 2: Give the hook its own entry point

**Files:**
- Create: `bin/tt-hook`
- Modify: `bin/tt`, `hooks/hooks.json`, `hooks/codex-hooks.json`, `tests/run.sh`, `README.md`

**Interfaces:**
- Consumes: `lib/tt-common.sh` from Task 1.
- Produces: `bin/tt-hook`, reading hook JSON on stdin, writing one row, exiting 0 always.

- [ ] **Step 1: Write the failing test**

Add assertions to `tests/run.sh` that `bin/tt-hook` exists, is executable, appends a 20-column beat when fed hook JSON on stdin, and exits 0 when `$TT_HOME` is unwritable.

- [ ] **Step 2: Run them, see them fail**

`sh tests/run.sh` — the new assertions fail because `bin/tt-hook` does not exist.

- [ ] **Step 3: Create `bin/tt-hook`**

Move `cmd_hook`'s body and its hook-only helpers into it. It sources `lib/tt-common.sh`, reads stdin, writes the row, and exits 0 unconditionally — a hook must never fail its harness. Bodies move unchanged.

- [ ] **Step 4: Leave a forwarder**

`tt hook` in `bin/tt` becomes a forwarder that execs `bin/tt-hook`, so an installed machine whose hook config still says `tt hook` keeps working. Note this in the README as the compatibility path.

- [ ] **Step 5: Point the hook config at it**

In `hooks/hooks.json` and `hooks/codex-hooks.json`, every command becomes the equivalent of

```
sh -c 'exec "${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}/bin/tt-hook"'
```

Keep the existing `${CLAUDE_PLUGIN_ROOT:-$PLUGIN_ROOT}` resolution and the `SessionEnd` timeout exactly as they are.

- [ ] **Step 6: Point the hook tests at it**

Every assertion that fed `tt hook` now feeds `bin/tt-hook`, plus one that keeps exercising the `tt hook` forwarder.

- [ ] **Step 7: Verify identical**

All three suites, same counts and names as Task 1 Step 1, plus the new assertions. Confirm `bin/tt` no longer contains the hook-only helpers, and measure the line counts of all three files for the report.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "Give the hook its own entry point"
```

---

## Verification

```bash
cd /home/lan/workspace/langerrr/timetrack-wt
PYTHONPATH=lib python3 -m unittest discover -s tests/python
sh tests/run.sh && dash tests/run.sh
wc -l bin/tt bin/tt-hook lib/tt-common.sh
printf '{"session_id":"s","hook_event_name":"Stop","cwd":"%s"}' "$PWD" | ./bin/tt-hook && echo "hook ok"
```

Expected: both suites green with the same assertion names as before the split, and `bin/tt-hook` materially smaller than `bin/tt`.
