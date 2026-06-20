# pueo-worklog

Private cross-machine convergence + evidence store for Chris's Claude-assisted work,
feeding Unanet timecards. Personal (`chris-pueo/pueo-worklog`), **private**, just for us.

> **Never clone or sync this repo inside OneDrive/SharePoint** — OneDrive and `.git`
> corrupt each other. Repos live under `C:\Users\ChrisGarrett\git\` (Windows) /
> `~/git/` (Linux).

## Layout

```
raw/                <machine>-YYYY-MM.ndjson   append-only session clock (the "when")
narrative/          <machine>-YYYY-MM.md       per-session "what" lines from non-OneDrive boxes (Linux)
rollups/            YYYY-MM.md                 generated Unanet-ready daily rollups (canonical, versioned)
claude/             CLAUDE.worklog.md          worklog instructions installed into ~/.claude/CLAUDE.md on Linux
bin/                hooks, Linux installer/cron, instruction installer
INSTALL-LINUX.md    how to wire a remote Linux box into this repo
```

On Linux, `bin/install-linux.sh` also installs the worklog instructions (charge codes +
ritual) into `~/.claude/CLAUDE.md` as a managed block, and the hourly cron keeps it fresh
from `claude/CLAUDE.worklog.md`. Linux sessions log per-session lines to `narrative/`
(OneDrive isn't mounted there); Windows `/timecard` reads `raw/` + `narrative/` to build rollups.

## How it flows

1. **Capture (per machine, automatic):** a Claude Code `SessionStart`/`SessionEnd` **+
   `UserPromptSubmit`** hook stamps wall-clock to `raw/<machine>-YYYY-MM.ndjson`.
   Machine-namespaced => no merge conflicts. SessionStart/End mark boundaries;
   `UserPromptSubmit` is a per-prompt **activity heartbeat** — the signal `/timecard`
   clusters into active time (lifecycle spans alone over/under-count). Windows hook:
   `~/.claude/worklog/claude-worklog-hook.ps1`; Linux hook: `bin/claude-worklog-hook.sh`
   (both installed into `~/.claude/settings.json`; see `INSTALL-LINUX.md`).
2. **Sync:** Linux pushes via cron (`bin/sync-push.sh`). Windows pushes when `/timecard` runs.
3. **Consolidate:** the `/timecard` Claude skill pulls this repo, merges every machine's
   clock + the per-session narrative lines, and writes the Unanet-ready rollups to BOTH
   `rollups/YYYY-MM.md` (here) and the human-read copy in
   `OneDrive\Claude\timekeeping\YYYY-MM.md`.

## Charge codes & format

The authoritative charge-code table, splitting rule, and line/rollup format live in the
human-facing copy: `OneDrive\Claude\timekeeping\README.md`. Default code is
**Technology_MGMT**; only A3IT lab-prep → **TESIEMS**, proposal infra → that proposal.

- Per-session line: `CODE Xhr: <summary + CHG/D/VLN/ClickUp refs>`
- Daily rollup: `CODE: X.XXhr: Completed: …; … Ongoing: …` (flat text, ≤300 chars)
- Hours rounded to 0.25hr.

## Privacy

Business-sensitive (program/proposal names, infra detail; possibly CUI-adjacent). Private
repo, high-level descriptions only, **no secrets** — consistent with Pueo repo rules.
