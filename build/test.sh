#!/bin/bash
# Fake gh + local bare repo standing in for GitHub; checks triggers, skips, worktree, retry, and auto-update.
set -euo pipefail
cd "$(dirname "$0")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --global user.name t; git config --global user.email t@t
git config --global url."$tmp/remote/".insteadOf "https://github.com/"

mkdir -p "$tmp/remote/o"; git init -q --bare -b main "$tmp/remote/o/r.git"
git clone -q "$tmp/remote/o/r.git" "$tmp/seed" 2>/dev/null
echo a > "$tmp/seed/f"; git -C "$tmp/seed" add f; git -C "$tmp/seed" commit -qm a; git -C "$tmp/seed" push -q origin HEAD:main
base1="$(git -C "$tmp/seed" rev-parse HEAD)"

# Issue state served by the fake gh. Edit these files to change what "GitHub" returns.
d="$tmp/gh-state"; mkdir -p "$d"
echo '[]' > "$d/asked"
echo WRITE > "$d/perm"; echo 0 > "$d/linked"; echo 0 > "$d/openpr"; echo null > "$d/edited"; echo '[]' > "$d/comments"

cat > "$tmp/gh" <<FAKE
#!/bin/bash
jqf=""; prev=""; for a in "\$@"; do [ "\$prev" = "--jq" ] && jqf="\$a"; prev="\$a"; done
case "\$1 \$2" in
  "api user") json='{"login":"me"}' ;;
  "search issues") json='[{"repository":{"nameWithOwner":"o/r"},"number":7,"url":"https://github.com/o/r/issues/7"},{"repository":{"nameWithOwner":"o/r"},"number":5,"url":"https://github.com/o/r/issues/5"},{"repository":{"nameWithOwner":"o/r"},"number":9,"url":"https://github.com/o/r/issues/9"}]' ;;
  "api graphql")
    case "\$*" in *"n=9"*) echo "HTTP 502" >&2; exit 1 ;; *"n=7"*) printf '%s' '{"data":{"repository":{"viewerPermission":"WRITE","defaultBranchRef":{"name":"main"},"issue":null}}}' | jq -r "\$jqf"; exit 0 ;; esac
    json="{\"data\":{\"repository\":{\"viewerPermission\":\"\$(cat $d/perm)\",\"defaultBranchRef\":{\"name\":\"main\"},\"issue\":{\"createdAt\":\"2026-01-01T00:00:00Z\",\"lastEditedAt\":\$(cat $d/edited),\"comments\":{\"nodes\":\$(cat $d/comments)},\"closedByPullRequestsReferences\":{\"totalCount\":\$(cat $d/linked)}}}}}" ;;
  "issue view") json="{\"comments\":\$(cat $d/asked)}" ;;
  "pr list") json="\$(jq -cn --argjson n "\$(cat $d/openpr)" '[range(\$n) | {number: .}]')" ;;
  "auth git-credential") exit 0 ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
if [ -n "\$jqf" ]; then printf '%s' "\$json" | jq -r "\$jqf"; else printf '%s' "\$json"; fi
FAKE
chmod +x "$tmp/gh"

# Fake agent: records where it ran, writes a scratch file, optionally commits+pushes.
cat > "$tmp/agent" <<AGENT
#!/bin/bash
echo "\$(pwd) \$(git rev-parse --abbrev-ref HEAD) \$(git rev-parse HEAD) :: \$1" >> "$tmp/agent.log"
mkdir -p .maintain-scratch && echo body > .maintain-scratch/pr-body.md
git status --porcelain >> "$tmp/agent-status.log"
if [ -e "$tmp/agent-push" ]; then echo work >> f; git commit -qam work; git push -q origin HEAD:refs/heads/agent/issue-5; fi
if [ ! -e "$tmp/agent-silent" ]; then echo '[{"author":{"login":"me"},"createdAt":"2099-01-01T00:00:00Z"}]' > "$d/asked"; fi
[ ! -e "$tmp/agent-fail" ]
AGENT
chmod +x "$tmp/agent"

mkdir -p "$tmp/claude"; echo '{"userID":"u","projects":{"/x":{"hasTrustDialogAccepted":true}}}' > "$tmp/claude/.claude.json"
export PATH="$tmp:$PATH" PR_BUILD_STATE_DIR="$tmp/state" PR_BUILD_AGENT_CMD="$tmp/agent" CLAUDE_CONFIG_DIR="$tmp/claude" PR_POLLERS_TRUST_CLAUDE=1
# Skip self-update for runs from this checkout so the test never moves the dev working copy to a tag.
export PR_POLLERS_UPDATED=1
calls() { if [ -e "$tmp/agent.log" ]; then wc -l < "$tmp/agent.log" | tr -d ' '; else echo 0; fi; }
poll() { ./poller.sh >/dev/null 2>"$tmp/stderr"; }

echo READ > "$d/perm"; poll; [ "$(calls)" = 0 ] || fail "ran without push access"
echo WRITE > "$d/perm"; echo 1 > "$d/linked"; poll; [ "$(calls)" = 0 ] || fail "ran with a linked open PR"
echo 0 > "$d/linked"; echo 1 > "$d/openpr"; poll; [ "$(calls)" = 0 ] || fail "ran with an open PR on agent/issue-5"
echo 0 > "$d/openpr"

poll; [ "$(calls)" = 1 ] || fail "labeled issue did not build: $(cat "$tmp/stderr")"
grep -q "skip o/r#9: issue lookup failed" "$tmp/stderr" || fail "failing issue not logged"
grep -q "skip o/r#7: issue not found" "$tmp/stderr" || fail "deleted issue not skipped (listed first, must not abort the pass)"
line="$(tail -1 "$tmp/agent.log")"
grep -q "worktrees/o__r-5 agent/issue-5 $base1 " <<< "$line" || fail "agent not on agent/issue-5 at default-branch head: $line"
grep -q "skills/issue-builder/SKILL.md" <<< "$line" || fail "prompt missing bundled skill path"
grep -q 'Closes #5' <<< "$line" || fail "prompt missing Closes #5"
grep -q "git push origin HEAD:refs/heads/agent/issue-5" <<< "$line" || fail "prompt missing push target"
[ ! -s "$tmp/agent-status.log" ] || fail "scratch files show in git status"
[ ! -e "$tmp/state/worktrees/o__r-5" ] || fail "worktree not removed"
# A user's global ssh rewrite must not apply in the poller's clones: they push over https with gh credentials.
[ "$(git -C "$tmp/state/repos/o/r" config --get url.https://github.com/.insteadOf)" = "https://github.com/" ] \
  || fail "clone does not pin https over a global url rewrite"
clonep="$(cd "$tmp/state/repos/o/r" && pwd -P)"
jq -e --arg p "$clonep" '.projects[$p].hasTrustDialogAccepted and .userID == "u"' "$tmp/claude/.claude.json" >/dev/null || fail "clone not trusted for Claude"

echo '[]' > "$d/asked"
poll; [ "$(calls)" = 1 ] || fail "unchanged issue built twice"
echo '[{"author":{"login":"me"},"createdAt":"2026-01-03T00:00:00Z"}]' > "$d/comments"
poll; [ "$(calls)" = 1 ] || fail "my own comment (e.g. the agent's question) retriggered"
echo '"2026-01-02T00:00:00Z"' > "$d/edited"
poll; [ "$(calls)" = 2 ] || fail "issue edit did not retrigger"
echo '[{"author":{"login":"me"},"createdAt":"2026-01-03T00:00:00Z"},{"author":{"login":"bob"},"createdAt":"2026-01-04T00:00:00Z"}]' > "$d/comments"
touch "$tmp/agent-fail"; poll; [ "$(calls)" = 3 ] || fail "someone else's comment did not retrigger"
rm "$tmp/agent-fail"; poll; [ "$(calls)" = 4 ] || fail "failed run not retried"

# Agent exits 0 but leaves no PR and no question (e.g. its push failed): retry, do not mark handled.
echo '"2026-01-04T12:00:00Z"' > "$d/edited"; echo '[]' > "$d/asked"; touch "$tmp/agent-silent"
poll; [ "$(calls)" = 5 ] || fail "edit did not retrigger before silent run"
poll; [ "$(calls)" = 6 ] || fail "run with no PR or question was marked handled"
rm "$tmp/agent-silent"; poll; [ "$(calls)" = 7 ] || fail "silent run not retried"
echo '[]' > "$d/asked"; poll; [ "$(calls)" = 7 ] || fail "run with a question was not marked handled"

# A branch pushed by an earlier run (no PR yet) is resumed, not restarted from main.
echo '"2026-01-05T00:00:00Z"' > "$d/edited"; touch "$tmp/agent-push"; poll; rm "$tmp/agent-push"
pushed="$(git -C "$tmp/remote/o/r.git" rev-parse refs/heads/agent/issue-5)"
echo '"2026-01-06T00:00:00Z"' > "$d/edited"; poll
grep -q "agent/issue-5 $pushed " <<< "$(tail -1 "$tmp/agent.log")" || fail "did not resume pushed agent/issue-5 branch"
grep -q "started from origin/agent/issue-5" <<< "$(tail -1 "$tmp/agent.log")" || fail "prompt does not say it resumed"

echo "ok"
