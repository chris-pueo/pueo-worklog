#!/usr/bin/env bash
# sync-push.sh — push this machine's worklog clock to the shared repo. Run from cron.
# Machine-namespaced raw files => never a content conflict; rebase orders commits.
# Single-instance via flock. Safe to run frequently (no-op when nothing changed).

repo="$HOME/git/pueo-worklog"
cd "$repo" 2>/dev/null || exit 0

# single instance
exec 9>"$repo/.sync.lock" 2>/dev/null || exit 0
command -v flock >/dev/null 2>&1 && { flock -n 9 || exit 0; }

git pull --rebase --autostash --quiet 2>/dev/null || true

# refresh the worklog instructions in ~/.claude/CLAUDE.md from the (just-pulled) repo
bash "$repo/bin/apply-instructions.sh" 2>/dev/null || true

git add raw/ narrative/ 2>/dev/null || true

if ! git diff --cached --quiet 2>/dev/null; then
  git -c user.name='Chris Garrett' -c user.email='chris@pueo.com' \
      commit -m "worklog: $(hostname -s 2>/dev/null || hostname) sync $(date -u +%Y-%m-%dT%H:%MZ)" --quiet 2>/dev/null || true
  # bounded push-retry: re-pull+rebase on a non-fast-forward, up to 3 times (self-heals races)
  for i in 1 2 3; do
    git push --quiet 2>/dev/null && break
    git pull --rebase --autostash --quiet 2>/dev/null || true
  done
fi
exit 0
