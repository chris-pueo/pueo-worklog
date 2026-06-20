## Worklog / timecard — record work as you go (Linux; managed by pueo-worklog)

Time + activity are logged so timecards write themselves. A SessionStart/SessionEnd +
UserPromptSubmit (per-prompt activity heartbeat) hook auto-captures wall-clock to
`~/git/pueo-worklog/raw/<host>-YYYY-MM.ndjson` (cron pushes it) — you do nothing for the clock.
(Heartbeat added 2026-06-20; if `jq '.hooks|keys' ~/.claude/settings.json` lacks
UserPromptSubmit, re-run `bash ~/git/pueo-worklog/bin/install-linux.sh`.)

**At the end of a substantive session, append ONE line** for the work done, under today's
date heading (create the heading if absent), to THIS machine's narrative file in the repo:
`~/git/pueo-worklog/narrative/<host>-YYYY-MM.md`
→ `CODE Xhr: <brief summary + CHG/D/VLN/ClickUp refs>`

(OneDrive is not mounted on Linux, so we log to the repo instead of the OneDrive worklog;
the hourly cron pushes it and Windows `/timecard` consolidates it into the Unanet rollups.)

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
