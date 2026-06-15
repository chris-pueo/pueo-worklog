#!/usr/bin/env bash
# apply-instructions.sh — install/refresh the worklog instructions into ~/.claude/CLAUDE.md
# on a Linux box, so Claude Code sessions there follow the worklog ritual + charge codes.
#
# Idempotent: replaces the content between the BEGIN/END markers (appends the block if
# absent), pulling the latest text from claude/CLAUDE.worklog.md. Called by install-linux.sh
# and by the hourly sync-push.sh (so a `git pull` of new instructions auto-applies).
# Never touches anything outside the marked block. Safe to run repeatedly.

repo="$HOME/git/pueo-worklog"
src="$repo/claude/CLAUDE.worklog.md"
dst="$HOME/.claude/CLAUDE.md"
[ -f "$src" ] || exit 0

mkdir -p "$HOME/.claude"
touch "$dst"

begin="<!-- BEGIN pueo-worklog (managed by pueo-worklog/bin/apply-instructions.sh — do not edit inside) -->"
end="<!-- END pueo-worklog -->"

tmp="$(mktemp)"
# keep everything OUTSIDE any existing managed block
awk -v b="$begin" -v e="$end" 'BEGIN{skip=0} $0==b{skip=1;next} $0==e{skip=0;next} skip==0{print}' "$dst" > "$tmp"

{
  cat "$tmp"
  printf '\n%s\n' "$begin"
  cat "$src"
  printf '%s\n' "$end"
} > "$dst.new" && mv "$dst.new" "$dst"

rm -f "$tmp"
exit 0
