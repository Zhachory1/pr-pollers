#!/bin/bash
# One polling pass: run the pr-review skill once per head SHA of each open,
# non-draft PR assigned to the authenticated gh user. launchd runs it on an
# interval and never overlaps runs of the same job.
set -euo pipefail

# Self-update to the newest v* tag, then re-exec so the pass runs one version end to end.
# Keep this block first, stable, and free of lib.sh: a release that breaks it cannot update its way out.
dir="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$dir/.." && pwd)"
if [ -z "${PR_POLLERS_UPDATED:-}" ] && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  export PR_POLLERS_UPDATED=1
  # Three jobs share this clone. mkdir is atomic: only one updates at a time; the others run their current
  # version this pass. A lock older than 10 minutes is from a killed pass and is cleared.
  lock="$(git -C "$root" rev-parse --absolute-git-dir)/pr-pollers-update.lock"
  find "$lock" -maxdepth 0 -mmin +10 -exec rmdir {} \; 2>/dev/null || true
  if ! mkdir "$lock" 2>/dev/null; then
    lock=""
    echo "$(date -u +%FT%TZ) another poller is updating; staying on current version" >&2
  elif git -C "$root" fetch -q --tags 2>/dev/null; then
    cur="$(git -C "$root" describe --tags --exact-match 2>/dev/null || true)"
    latest="$(git -C "$root" tag -l 'v*' --sort=-v:refname | head -1)"
    if [ -n "$latest" ] && [ "$cur" != "$latest" ]; then
      if git -C "$root" -c advice.detachedHead=false checkout -q "$latest" 2>/dev/null; then
        echo "$(date -u +%FT%TZ) updated ${cur:-untagged} -> $latest"
        if [ -n "$cur" ] && ! git -C "$root" diff --quiet "$cur" "$latest" -- SKILL.md; then
          echo "$(date -u +%FT%TZ) $latest changes install steps; ask your agent to update the pr-pollers" >&2
        fi
        rmdir "$lock"
        exec /bin/bash "$dir/poller.sh" "$@"
      fi
      echo "$(date -u +%FT%TZ) could not check out $latest (local changes?); staying on ${cur:-current}" >&2
    fi
  else
    echo "$(date -u +%FT%TZ) tag fetch failed; staying on current version" >&2
  fi
  if [ -n "$lock" ]; then rmdir "$lock" 2>/dev/null || true; fi
fi

: "${PR_REVIEW_AGENT_CMD:?set PR_REVIEW_AGENT_CMD to a non-interactive agent command that takes the prompt as its last argument}"
STATE_DIR="${PR_REVIEW_STATE_DIR:-$HOME/.local/state/pr-pollers/review}"
SEEN="$STATE_DIR/pr-review-seen"
mkdir -p "$STATE_DIR"
touch "$SEEN"

# shellcheck source=lib.sh
. "$root/lib.sh"

me="$(gh api user --jq .login)"
prs="$(gh search prs --assignee @me --state open --limit 100 --json repository,number,url,isDraft,author \
  --jq ".[] | select((.isDraft | not) and .author.login != \"$me\") | [.repository.nameWithOwner, .number, .url] | @tsv")"

[ -n "$prs" ] || exit 0
while IFS=$'\t' read -r repo number url; do
  # Guard every external call: one broken PR must not stop the pass for the others.
  skip() { echo "$(date -u +%FT%TZ) skip $repo#$number: $1" >&2; }
  sha="$(gh pr view "$number" -R "$repo" --json headRefOid --jq .headRefOid)" || { skip "gh pr view failed"; continue; }
  key="$repo#$number@$sha"
  if grep -Fxq "$key" "$SEEN"; then continue; fi
  # GitHub is the source of truth: skip if this user already reviewed this exact SHA (by hand, another machine, or a run that posted then failed).
  reviewed="$(gh api "repos/$repo/pulls/$number/reviews" --paginate \
    --jq ".[] | select(.user.login == \"$me\" and .commit_id == \"$sha\") | .id")" || { skip "reviews lookup failed"; continue; }
  if [ -n "$reviewed" ]; then echo "$key" >> "$SEEN"; continue; fi
  echo "$(date -u +%FT%TZ) reviewing $key"
  prompt="Use the pr-review skill to review $url at head SHA $sha. Post the review per the skill's delivery contract."
  if run_agent "$PR_REVIEW_AGENT_CMD" "$PWD" "$prompt"; then
    echo "$key" >> "$SEEN"
  else
    echo "$(date -u +%FT%TZ) review failed for $key; will retry next pass" >&2
  fi
done <<< "$prs"
