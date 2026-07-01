## Worklog / timecard — record work as you go (Linux; managed by pueo-worklog)

Time + activity are logged so timecards write themselves. A SessionStart/SessionEnd +
UserPromptSubmit (per-prompt activity heartbeat) hook auto-captures wall-clock to
`~/git/pueo-worklog/raw/<host>-YYYY-MM.ndjson` (cron pushes it) — you do nothing for the clock.
(Heartbeat added 2026-06-20; if `jq '.hooks|keys' ~/.claude/settings.json` lacks
UserPromptSubmit, re-run `bash ~/git/pueo-worklog/bin/install-linux.sh`.)

**At the end of a substantive session, append ONE line** for the work done, under today's
date heading (create the heading if absent), to THIS machine's narrative file in the repo:
`~/git/pueo-worklog/narrative/<host>-YYYY-MM.md`
→ `CODE Xhr: <brief summary + CHG/D/VLN/ClickUp refs> [sid:<session_id>]`

**End every line with `[sid:<session_id>]`** — your session id is the UUID in your scratchpad
path (`/tmp/claude-*/<...>/<SESSION_ID>/scratchpad`). This is not decoration: the SessionEnd
hook uses it to tell a described session from an undescribed one. Dates are **LOCAL** (the
heading + file month), matching the clock (the hook now stamps local time + offset), so a day
never splits across two buckets. **Don't sit on the line — write it before the session ends**,
because a session that ends via `/clear`, context exhaustion, or a closed terminal can't be
described after the fact.

Backstop + reconcile: if a session ends with no `[sid:...]` line, the SessionEnd hook appends
a `Technology_MGMT ?hr: [PENDING — ...] [sid:...]` stub under today's heading so the gap is
visible, not silently lost. Run `bash ~/git/pueo-worklog/bin/reconcile-narrative.sh [YYYY-MM-DD]`
(default today) to list every session vs its narrative coverage and see what still needs a
real line; replace each PENDING stub with the real `CODE Xhr: …` line (keep its `[sid:...]`).

(OneDrive is not mounted on Linux, so we log to the repo instead of the OneDrive worklog;
the hourly cron pushes it and Windows `/timecard` consolidates it into the Unanet rollups.)

### Non-optional captures — the Stop-hook forcing function

A `Stop` hook (`bin/session-obligations.sh`) enforces the three mandatory captures at the end
of each substantive turn. It is deterministic (one jq pass over the transcript), fail-open,
and subagent-safe. The three obligations:

- **TIME** — *never blocks.* The hook auto-writes the `[sid:]` PENDING stub if the session did
  work and has no real line yet. You still upgrade the stub to a real `CODE Xhr: … [sid:]`
  line (that's the ritual above); the stub is just the guaranteed floor so nothing is lost.
- **CLICKUP** — if the session did task-worthy project work and no ClickUp update is detected,
  the hook blocks once (in `block` mode). Fulfill it (update the task, assigned to yourself),
  **or** write `NO-CLICKUP: <one-line reason>` in your reply if it genuinely isn't warranted.
- **OBSIDIAN** — if a KM/docs artifact was warranted (new `.md`, a `decisions.md`/`changelog.md`/
  ADR edit, or a `docs/`|`runbooks/` path) and no vault write is detected, the hook blocks once.
  Fulfill it, **or** write `NO-KM: <one-line reason>`.

Escape valves (honor system): `PUEO_OBLIG_MODE=block|remind` (default **remind** — soft
reminder, no block — until the team flips it to `block`); `PUEO_OBLIG=0` disables all;
`PUEO_OBLIG_CLICKUP=0` / `PUEO_OBLIG_KM=0` disable one; a `.no-obligations` file in a repo
opts that repo out. View/clear debts with `bash ~/git/pueo-worklog/bin/obligations-doctor.sh`
(unmet ClickUp/Obsidian obligations are recorded to a pushed ledger, never silently lost).

### Charge codes (default = Technology_MGMT)
| Abbrev | Unanet project | Books to |
|---|---|---|
| CRICKET | `2-3-13-0026-0025-1-CRICKET` | Infra in support of the Cricket proposal |
| TRUSTS | `0033_TRUSTS` | Capture work for the TRUSTS proposal |
| ESITA3 | `C-G-P-ESITA3-CYBR-0005-3001AA` | ESITA3 cyber / RMF program work |
| TESIEMS | `C-G-P-TESIEMS-IRSARC-0017-30B` | **A3IT lab prep ONLY** — vCenter/ESXi patching, boilerplate VMs, Docker Swarm, Palo base network/systems enablement |
| Technology_MGMT | `TECHNOLOGY_MGMT_2026` | **Catch-all** — all other infra/tech/IR&D + the rest of the lab work |

Splitting rule: only A3IT lab-prep → **TESIEMS**; live-proposal infra → that proposal
(**CRICKET**/**TRUSTS**); ESITA3 RMF → **ESITA3**; everything else → **Technology_MGMT**.

Format: per-line `CODE Xhr: …`. Hours are **distinct wall-clock** (parallel sessions are
not double-counted). The daily rollup (`CODE: X.XXhr: Completed: …; Ongoing: …`, flat text,
≤300 chars, 0.25hr) is generated on Windows by `/timecard` — you only write per-line entries here.
