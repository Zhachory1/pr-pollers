#!/bin/bash
# Fake gh + local bare repo standing in for GitHub; checks triggers, skips, worktree, retry, and auto-update.
set -euo pipefail
cd "$(dirname "$0")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --global user.name t; git config --global user.email t@t
# Route github.com HTTPS to the local bare repos.
git config --global url."$tmp/remote/".insteadOf "https://github.com/"

mkdir -p "$tmp/remote/o"; git init -q --bare -b main "$tmp/remote/o/r.git"
git clone -q "$tmp/remote/o/r.git" "$tmp/seed"
echo a > "$tmp/seed/f"; git -C "$tmp/seed" add f; git -C "$tmp/seed" commit -qm a
git -C "$tmp/seed" push -q origin HEAD:feat
sha1="$(git -C "$tmp/seed" rev-parse HEAD)"

# PR state served by the fake gh. Edit these files to change what "GitHub" returns.
d="$tmp/pr"; mkdir -p "$d"
echo "$sha1" > "$d/sha"; echo '[]' > "$d/labels"; echo false > "$d/fork"
echo '[]' > "$d/reviews"; echo '[]' > "$d/comments"; echo '[]' > "$d/inline"
echo '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]' > "$d/checks"

cat > "$tmp/gh" <<FAKE
#!/bin/bash
jqf=""; prev=""; for a in "\$@"; do [ "\$prev" = "--jq" ] && jqf="\$a"; prev="\$a"; done
case "\$1 \$2" in
  "api user") json='{"login":"me"}' ;;
  "search prs") json='[{"repository":{"nameWithOwner":"o/r"},"number":3,"isDraft":false},{"repository":{"nameWithOwner":"o/r"},"number":1,"isDraft":false},{"repository":{"nameWithOwner":"o/r"},"number":2,"isDraft":true}]' ;;
  "pr view") [ "\$3" = 3 ] && { echo "HTTP 502" >&2; exit 1; }
    json="{\"url\":\"https://github.com/o/r/pull/1\",\"headRefOid\":\"\$(cat $d/sha)\",\"headRefName\":\"feat\",\"isCrossRepository\":\$(cat $d/fork),\"labels\":\$(cat $d/labels),\"reviews\":\$(cat $d/reviews),\"comments\":\$(cat $d/comments),\"statusCheckRollup\":\$(cat $d/checks)}" ;;
  "api repos/o/r/pulls/1/comments") json="\$(cat $d/inline)" ;;
  "auth git-credential") exit 0 ;;
  *) echo "unexpected gh \$*" >&2; exit 1 ;;
esac
if [ -n "\$jqf" ]; then printf '%s' "\$json" | jq -r "\$jqf"; else printf '%s' "\$json"; fi
FAKE
chmod +x "$tmp/gh"

# Fake agent: records the prompt and where it ran (cwd + HEAD).
cat > "$tmp/agent" <<AGENT
#!/bin/bash
echo "\$(pwd) \$(git rev-parse HEAD) :: \$1" >> "$tmp/agent.log"
mkdir -p .maintain-scratch && echo body > .maintain-scratch/issue.md
git status --porcelain >> "$tmp/agent-status.log"
[ ! -e "$tmp/agent-fail" ]
AGENT
chmod +x "$tmp/agent"

mkdir -p "$tmp/claude"; echo '{"userID":"u","projects":{"/x":{"hasTrustDialogAccepted":true}}}' > "$tmp/claude/.claude.json"
export PATH="$tmp:$PATH" PR_MAINTAIN_STATE_DIR="$tmp/state" PR_MAINTAIN_AGENT_CMD="$tmp/agent" CLAUDE_CONFIG_DIR="$tmp/claude" PR_POLLERS_TRUST_CLAUDE=1
# Skip self-update for runs from this checkout so the test never moves the dev working copy to a tag.
export PR_POLLERS_UPDATED=1
calls() { if [ -e "$tmp/agent.log" ]; then wc -l < "$tmp/agent.log" | tr -d ' '; else echo 0; fi; }
poll() { ./poller.sh >/dev/null 2>"$tmp/stderr"; }

poll; [ "$(calls)" = 0 ] || fail "ran with no feedback and green CI"

echo '[{"author":{"login":"me"},"createdAt":"2026-01-01T00:00:01Z"}]' > "$d/comments"
echo '[{"author":{"login":"me"},"submittedAt":"2026-01-01T00:00:01Z"}]' > "$d/reviews"
echo '[{"user":{"login":"me"},"created_at":"2026-01-01T00:00:02Z"}]' > "$d/inline"
poll; [ "$(calls)" = 0 ] || fail "my own comments or reviews triggered a run"

echo '[{"author":{"login":"bob"},"submittedAt":"2026-01-01T00:00:03Z"}]' > "$d/reviews"
echo '[{"__typename":"CheckRun","status":"IN_PROGRESS","conclusion":null}]' > "$d/checks"
poll; [ "$(calls)" = 0 ] || fail "ran while CI pending"

echo '[{"__typename":"StatusContext","state":"SUCCESS"}]' > "$d/checks"
poll; [ "$(calls)" = 1 ] || fail "new review did not trigger a run (a failing PR listed first must not stop the pass)"
grep -q "skip o/r#3: gh pr view failed" "$tmp/stderr" || fail "failing PR not logged"
line="$(tail -1 "$tmp/agent.log")"
grep -q "$sha1" <<< "$line" || fail "agent not at head SHA"
grep -q "worktrees/o__r-1 " <<< "$line" || fail "agent not in per-PR worktree"
grep -q "skills/pr-review-handler/SKILL.md" <<< "$line" || fail "prompt missing bundled skill path"
grep -q "git push origin HEAD:feat" <<< "$line" || fail "prompt missing push target"
[ ! -e "$tmp/state/worktrees/o__r-1" ] || fail "worktree not removed"
# A user's global ssh rewrite must not apply in the poller's clones: they push over https with gh credentials.
[ "$(git -C "$tmp/state/repos/o/r" config --get url.https://github.com/.insteadOf)" = "https://github.com/" ] \
  || fail "clone does not pin https over a global url rewrite"
clonep="$(cd "$tmp/state/repos/o/r" && pwd -P)"
jq -e --arg p "$clonep" '.projects[$p].hasTrustDialogAccepted == true and .userID == "u" and .projects["/x"].hasTrustDialogAccepted' "$tmp/claude/.claude.json" >/dev/null \
  || fail "clone not trusted for Claude, or other .claude.json keys lost"
git -C "$tmp/state/repos/o/r" config --get-all credential.helper | grep -q "gh auth git-credential" || fail "clone missing gh credential helper"

[ ! -s "$tmp/agent-status.log" ] || fail "scratch files show in git status: $(cat "$tmp/agent-status.log")"
poll; [ "$(calls)" = 1 ] || fail "same feedback ran twice"

echo '[{"user":{"login":"amy"},"created_at":"2026-01-01T00:00:09Z"}]' > "$d/inline"
poll; [ "$(calls)" = 2 ] || fail "new inline comment did not trigger a run"

echo '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]' > "$d/checks"
poll; [ "$(calls)" = 3 ] || fail "failing CI did not trigger a run"
poll; [ "$(calls)" = 3 ] || fail "same failing SHA ran twice"

echo b > "$tmp/seed/f"; git -C "$tmp/seed" commit -qam b; git -C "$tmp/seed" push -q origin HEAD:feat
sha2="$(git -C "$tmp/seed" rev-parse HEAD)"; echo "$sha2" > "$d/sha"
touch "$tmp/agent-fail"
./poller.sh >/dev/null 2>&1; [ "$(calls)" = 4 ] || fail "new failing SHA did not trigger a run"
grep -q "$sha2" <<< "$(tail -1 "$tmp/agent.log")" || fail "agent not at new head SHA"
grep -q "ci $sha2" "$tmp/state/handled" && fail "failed run marked handled"
rm "$tmp/agent-fail"
poll; [ "$(calls)" = 5 ] || fail "failed run not retried"
poll; [ "$(calls)" = 5 ] || fail "retried run ran again"

echo '[{"author":{"login":"bob"},"createdAt":"2026-01-02T00:00:00Z"}]' > "$d/comments"
echo '[{"name":"no-maintain"}]' > "$d/labels"
poll; [ "$(calls)" = 5 ] || fail "no-maintain label not skipped"
echo '[]' > "$d/labels"; echo true > "$d/fork"
poll; [ "$(calls)" = 5 ] || fail "fork PR not skipped"
echo false > "$d/fork"
poll; [ "$(calls)" = 6 ] || fail "new PR comment did not trigger a run"

echo "ok"
