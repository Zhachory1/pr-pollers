#!/bin/bash
# Fake gh + fake agent; checks one review per head SHA, skips drafts/self-authored PRs and SHAs already reviewed on GitHub, retries failures.
set -euo pipefail
cd "$(dirname "$0")"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo aaa > "$tmp/sha"
# Reviews by someone else, or by me at an older SHA, must not count.
echo '[{"id":1,"user":{"login":"bob"},"commit_id":"aaa"},{"id":2,"user":{"login":"me"},"commit_id":"old"}]' > "$tmp/reviews"
cat > "$tmp/gh" <<FAKE
#!/bin/bash
jqf=""; prev=""; for a in "\$@"; do [ "\$prev" = "--jq" ] && jqf="\$a"; prev="\$a"; done
case "\$1 \$2" in
  "api user") json='{"login":"me"}' ;;
  "search prs") json='[{"repository":{"nameWithOwner":"o/r"},"number":4,"url":"u4","isDraft":false,"author":{"login":"bob"}},{"repository":{"nameWithOwner":"o/r"},"number":1,"url":"https://github.com/o/r/pull/1","isDraft":false,"author":{"login":"bob"}},{"repository":{"nameWithOwner":"o/r"},"number":2,"url":"u2","isDraft":true,"author":{"login":"bob"}},{"repository":{"nameWithOwner":"o/r"},"number":3,"url":"u3","isDraft":false,"author":{"login":"me"}}]' ;;
  "pr view") [ "\$3" = 4 ] && { echo "HTTP 502" >&2; exit 1; }
    json="{\"headRefOid\":\"\$(cat $tmp/sha)\"}" ;;
  "api repos/o/r/pulls/1/reviews") json="\$(cat $tmp/reviews)" ;;
esac
printf '%s' "\$json" | jq -r "\$jqf"
FAKE
chmod +x "$tmp/gh"
# Fake agent: records the prompt and "posts" a review at the current SHA, unless told it posted nothing.
cat > "$tmp/agent" <<AGENT
#!/bin/bash
echo "\$1" >> "$tmp/agent.log"
if [ ! -e "$tmp/agent-silent" ]; then
  jq -c --arg s "\$(cat "$tmp/sha")" '. + [{"id":99,"user":{"login":"me"},"commit_id":\$s}]' "$tmp/reviews" > "$tmp/reviews.new" && mv "$tmp/reviews.new" "$tmp/reviews"
fi
AGENT
chmod +x "$tmp/agent"
export PATH="$tmp:$PATH" PR_REVIEW_STATE_DIR="$tmp/state" PR_REVIEW_AGENT_CMD="$tmp/agent"
# Skip self-update for runs from this checkout so the test never moves the dev working copy to a tag.
export PR_POLLERS_UPDATED=1
fail() { echo "FAIL: $*" >&2; exit 1; }

./poller.sh >/dev/null 2>"$tmp/stderr"; ./poller.sh >/dev/null 2>&1
grep -q "skip o/r#4: gh pr view failed" "$tmp/stderr" || fail "failing PR listed first was not skipped"
[ "$(wc -l < "$tmp/agent.log")" -eq 1 ] || fail "expected one review for PR 1 at aaa"
grep -q 'pull/1 at head SHA aaa' "$tmp/agent.log" || fail "wrong prompt"

echo bbb > "$tmp/sha"; ./poller.sh >/dev/null
[ "$(wc -l < "$tmp/agent.log")" -eq 2 ] || fail "new SHA not re-reviewed"
grep -q "head SHA bbb" "$tmp/agent.log" || fail "wrong prompt for new SHA"

echo ccc > "$tmp/sha"; PR_REVIEW_AGENT_CMD=false ./poller.sh >/dev/null 2>&1
grep -q ccc "$tmp/state/pr-review-seen" && fail "failed review marked seen"

echo ddd > "$tmp/sha"
echo '[{"id":3,"user":{"login":"me"},"commit_id":"ddd"}]' > "$tmp/reviews"
./poller.sh >/dev/null
[ "$(wc -l < "$tmp/agent.log")" -eq 2 ] || fail "SHA already reviewed on GitHub was reviewed again"
grep -Fxq 'o/r#1@ddd' "$tmp/state/pr-review-seen" || fail "SHA reviewed on GitHub not recorded as seen"

# Agent exits 0 but posts nothing: the SHA is not recorded and the next pass retries.
echo eee > "$tmp/sha"; touch "$tmp/agent-silent"; n="$(wc -l < "$tmp/agent.log")"
./poller.sh >/dev/null 2>"$tmp/stderr"
grep -Fxq 'o/r#1@eee' "$tmp/state/pr-review-seen" && fail "SHA recorded without a posted review"
grep -q "no review posted for o/r#1@eee" "$tmp/stderr" || fail "missing review not logged"
rm "$tmp/agent-silent"; ./poller.sh >/dev/null 2>&1
[ "$(wc -l < "$tmp/agent.log")" -eq $((n + 2)) ] || fail "silent run not retried"
grep -Fxq 'o/r#1@eee' "$tmp/state/pr-review-seen" || fail "posted review not recorded"
echo "ok"
