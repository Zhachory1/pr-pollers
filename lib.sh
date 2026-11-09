# shellcheck shell=bash
# Shared helpers for the pr-pollers. Sourced by each <name>/poller.sh after its self-update block.
# Callers set: me (gh login), STATE_DIR, log().

# Claude Code ignores a repo's .claude/settings.json (e.g. its test-command allowlist) until the
# workspace is trusted. Trust must be on the exact clone; worktrees resolve to it. Opt-in, set at install.
claude_trust() {
  local cfg="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json" p tmp
  [ -f "$cfg" ] || return 0
  p="$(cd "$1" && pwd -P)"
  jq -e --arg p "$p" '.projects[$p].hasTrustDialogAccepted == true' "$cfg" >/dev/null 2>&1 && return 0
  tmp="$(mktemp "$cfg.XXXXXX")" || return 1
  if jq --arg p "$p" '.projects[$p].hasTrustDialogAccepted = true' "$cfg" > "$tmp"; then mv "$tmp" "$cfg"; else rm -f "$tmp"; return 1; fi
}

# Cached clone of $1 (owner/repo) at $2, pushing over HTTPS with gh credentials. Returns non-zero if the clone fails.
ensure_clone() {
  local repo="$1" clone="$2"
  if [ ! -d "$clone/.git" ]; then
    git -c credential.helper= -c 'credential.helper=!gh auth git-credential' -c url.https://github.com/.insteadOf=https://github.com/ \
      clone -q --no-checkout "https://github.com/$repo.git" "$clone" || { rm -rf "$clone"; return 1; }
    git -C "$clone" config credential.helper ''
    git -C "$clone" config --add credential.helper '!gh auth git-credential'
  fi
  # Pin HTTPS in this clone: a global url.<ssh>.insteadOf would push with the SSH key's account, not gh's. Set on every pass so existing clones are fixed too.
  git -C "$clone" config url.https://github.com/.insteadOf https://github.com/
  # Agents write temp files to .maintain-scratch/; keep them out of commits (info/exclude is shared by all worktrees).
  grep -qxF '.maintain-scratch/' "$clone/.git/info/exclude" 2>/dev/null || echo '.maintain-scratch/' >> "$clone/.git/info/exclude"
  if [ -n "${PR_POLLERS_TRUST_CLAUDE:-}" ]; then claude_trust "$clone" || log "could not mark $clone trusted for Claude" >&2; fi
}

# Fresh worktree at $2 for clone $1, created by the remaining git worktree add arguments.
fresh_worktree() {
  local clone="$1" wt="$2"; shift 2
  git -C "$clone" worktree remove --force "$wt" 2>/dev/null || rm -rf "$wt"
  git -C "$clone" worktree prune
  git -C "$clone" worktree add -q "$@"
}

drop_worktree() { git -C "$1" worktree remove --force "$2" 2>/dev/null || rm -rf "$2"; }

# Run the agent command $1 in directory $2 with prompt $3.
run_agent() { (cd "$2" && /bin/bash -c "$1 \"\$1\"" pr-pollers "$3" </dev/null); }
