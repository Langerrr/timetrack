# Codex hook integration review

Reviewed the completed plans and cleanup after `e169964` against installed
**Codex CLI 0.153.4**, its generated app-server schema, and actual local runtime
experiments. The implementation and cleanup are complete. The compatibility
verdict is **partial**: event capture and accounting work after the repairs
below, but native Codex goal activation cannot automatically select solo mode
from the hook payload currently supplied.

## Runtime evidence

Tests installed a copy of the worktree through `codex plugin marketplace add`
and `codex plugin add` into a temporary Codex home. They used a loopback HTTP
provider returning predetermined Responses events, with no request to an external model
service. The fixture selected GPT-5.5 protocol metadata to expose ordinary
function calls and enabled code mode and multi-agent v2 where exercised; this
was protocol simulation, not a model evaluation. No live time log or installed
user plugin was changed.

`codex app-server generate-json-schema --experimental` established the installed
protocol. `hooks/list` discovered exactly nine handlers from the manifest's
`hooks/codex-hooks.json`, initially untrusted. Persisting the reviewed hashes
in the temporary configuration made all nine trusted. SessionEnd retained its
three-second timeout; Interrupt used Codex's one-second default. No hook-trust
bypass flag was used.

| Requirement | Observed evidence |
| --- | --- |
| Standalone entry point and plugin root | Installed manifest commands executed `bin/tt-hook`; beats identified the harness as Codex even with compatibility Claude variables present. |
| SessionStart, UserPromptSubmit, Stop, SessionEnd | Actual runtime events produced twenty-column rows, turn/session IDs, source, and no hook output or failures. |
| PreToolUse / PostToolUse | Successful direct `exec_command` and nested code-mode execution produced matching tool IDs and canonical `Bash` names. Failed tool calls were also observed in the initial nested-sandbox run. |
| Interrupt | A pending local provider response was interrupted through `turn/interrupt`; the hook completed and emitted its beat. |
| SubagentStart / SubagentStop | Actual multi-agent v2 execution emitted both lifecycle events. Child tool events shared the parent session, carried the child's `agent_id`, and retained independent tool IDs. |
| Literal slash classifier | Passing `/goal smoke` as a prompt produced `trigger`, then `machine` on exact replay; human follow-ups remained `human`. Exactly one automatic solo transition was written. |
| Native goal lifecycle | `thread/goal/set` followed by the objective prompt produced an ordinary human prompt and no solo transition. The next automatic goal turn emitted Stop without another UserPromptSubmit. |
| Reporting and rollover | Focused exact-second regressions cover child lifetimes, own-tool subtraction, shutdown, and incremental/repeated compaction. All four copied-log report views remained stable. |

The successful parent/child fixture independently measured **two workers,
2 agent seconds, and 4 tool seconds**, including a three-second child lifetime.
The repaired reporter matched those totals. These are measured fixture values,
not rounded report estimates.

## Repaired findings

1. **Shutdown billed idle time.** A prompt at 0, Stop at 50, and SessionEnd at
   200 previously reported 200 agent seconds. Shutdown now closes an open turn
   without extending a completed turn or seeding a continuation. The result is
   50 seconds, including across rollover. Genuine Stop-to-Stop continuation is
   retained.
2. **Codex child time was missing.** Codex's asynchronous spawn returned before
   its child finished. The observed tool name was `collaborationspawn_agent`;
   the synchronous Task/Agent inference could not measure that worker.
   Codex now uses explicit SubagentStart/Stop intervals and subtracts tools by
   the observed child identity. It does not create a second worker from the
   spawn-call duration. Claude-style synchronous inference remains intact.
3. **Bundled instructions described the retired model.** The skill still
   explained ESTIMATED reading time and editing compact totals to correct
   manual effort. It now describes EFFORT versus AGENT/TOOL and the limits of
   correcting coalesced coverage. Plugin descriptions and trust instructions
   were brought into alignment.

Six new accounting tests failed before their corresponding fixes; all now
pass. The additional manifest test drives all nine real configured commands
with Codex payload fields, including nested tool input and child IDs.

## Native goal gap

The plan assumed unattended commands arrive as literal slash prompts or replay
their initial prompt. That assumption does **not** describe native Codex goals
in 0.153.4. Instrumenting an isolated copy to record synthetic hook payloads
confirmed that goal activation exposes the ordinary objective text, with no
goal-start field. Automatic continuation does not invoke UserPromptSubmit.
Consequently it creates no false human heartbeat, but the hook also has no
reliable basis for the planned automatic solo transition.

Explicit `tt solo` before leaving a native goal unattended is a workaround.
It is **not** completion of native goal auto-detection. That behavior needs a
client-side goal-start signal or an integration outside the current hook
contract. We did not infer goal state from permission mode or ordinary prompt
text, and did not add transcript/database scraping. This remains an explicit
compatibility finding from the requested review.

The [Codex hooks documentation](https://learn.chatgpt.com/docs/hooks) describes
the current trust flow, event fields, and local tool coverage. Hosted tools
such as WebSearch do not emit local tool hooks, so their time cannot be split
out as TOOL through this interface. The
[goal documentation](https://learn.chatgpt.com/docs/long-running-work) describes
the objective as the initial prompt; literal slash-prompt injection is not a
substitute for testing native goal activation.

## Final verification and deployment state

- Python: **156 passed**.
- Shell: **214 passed under sh**, **214 passed under dash**, separate temporary roots.
- Copied-log CLI rollover and repeat reporting: **all four views passed**.
- sh/dash source syntax, eleven runtime modules' Python 3.8 grammar, and diff whitespace checks passed.
- Actual runtime hooks across the combined fixtures: **all nine event types observed**.

The user-installed cache remains version 0.5.0 from the original main checkout;
it does not contain this branch's new entry point. Local implementation and
verification are complete; merge/reinstall and renewed hook trust are separate
integration steps and were not performed.

Temporary raw evidence is retained at `/tmp/tt-codex-integration-e54xitk4`
(direct/nested tools and interruption), `/tmp/tt-codex-integration-bum3g177`
(parent and child tools), and `/tmp/tt-codex-integration-e_yksuam` (instrumented
native goal payloads). The protocol fixture scripts are
`/tmp/tt-codex-full-probe.py`, `/tmp/tt-codex-child-tools-probe.py`, and
`/tmp/tt-codex-goal-payload-probe.py`. Durable regression coverage is in
`tests/python/test_codex_hooks.py`; the runtime probes additionally require the
installed Codex binary and permission to create Codex's own sandbox.
