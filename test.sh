#!/bin/bash
# Runs every poller's tests, then checks self-update for the combined repo.
set -euo pipefail
cd "$(dirname "$0")"
fail() { echo "FAIL: $*" >&2; exit 1; }
for n in review maintain build; do
  out="$("./$n/test.sh" 2>&1)" || fail "$n: $(tail -3 <<< "$out")"
  echo "$n ok"
done

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export GIT_CONFIG_GLOBAL="$tmp/gitconfig"
git config --global user.name t; git config --global user.email t@t
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'GH'
#!/bin/bash
[ "$1 $2" = "api user" ] && echo me
exit 0
GH
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" PR_REVIEW_AGENT_CMD=true PR_MAINTAIN_AGENT_CMD=true PR_BUILD_AGENT_CMD=true
export PR_REVIEW_STATE_DIR="$tmp/s/review" PR_MAINTAIN_STATE_DIR="$tmp/s/maintain" PR_BUILD_STATE_DIR="$tmp/s/build"
unset PR_POLLERS_UPDATED

# Upstream = this working tree's files at two tags. Each poller self-updates the whole repo.
up="$tmp/upstream"; mkdir "$up"
cp -R lib.sh review maintain build "$up/"; echo v1 > "$up/SKILL.md"
git -C "$up" init -q; git -C "$up" add -A; git -C "$up" commit -qm v1; git -C "$up" tag v0.1.0
for n in review maintain build; do
  # shellcheck disable=SC2016 # literal match on the script text
  sed -i.bak 's|^: "\${PR_[A-Z]*_AGENT_CMD:?|echo NEW-CODE-RAN-'"$n"'\n&|' "$up/$n/poller.sh"; rm "$up/$n/poller.sh.bak"
done
git -C "$up" commit -qam v2; git -C "$up" tag v0.10.0
inst="$tmp/inst"; git clone -q "$up" "$inst"; git -C "$inst" -c advice.detachedHead=false checkout -q v0.1.0

out="$(/bin/bash "$inst/build/poller.sh" 2>&1)" || fail "update pass failed: $out"
[ "$(git -C "$inst" describe --tags)" = v0.10.0 ] || fail "did not update to newest tag (v0.10.0 sorts above v0.1.0)"
grep -q NEW-CODE-RAN-build <<< "$out" || fail "new code did not run in the same pass"
grep -q 'updated v0.1.0 -> v0.10.0' <<< "$out" || fail "update not logged"
grep -q 'install steps' <<< "$out" && fail "install-step warning without a SKILL.md change"
for n in review maintain; do
  out="$(/bin/bash "$inst/$n/poller.sh" 2>&1)" || fail "$n pass after update failed: $out"
  grep -q "NEW-CODE-RAN-$n" <<< "$out" || fail "$n is not running the updated code"
  grep -q updated <<< "$out" && fail "$n updated again after another poller already did"
done

echo v3 > "$up/SKILL.md"; git -C "$up" commit -qam v3; git -C "$up" tag v0.11.0
out="$(/bin/bash "$inst/review/poller.sh" 2>&1)" || fail "update pass failed"
grep -q 'v0.11.0 changes install steps; ask your agent to update the pr-pollers' <<< "$out" || fail "SKILL.md change not flagged"

git -C "$inst" remote set-url origin "$tmp/missing"
out="$(/bin/bash "$inst/maintain/poller.sh" 2>&1)" || fail "pass failed when fetch failed: $out"
[ "$(git -C "$inst" describe --tags)" = v0.11.0 ] || fail "version changed after failed fetch"

# Another poller holding the update lock: this one runs its current version and leaves the lock alone.
git -C "$inst" remote set-url origin "$up"
echo v4 > "$up/lib.sh.v4"; git -C "$up" add -A; git -C "$up" commit -qm v4; git -C "$up" tag v0.12.0
lock="$(git -C "$inst" rev-parse --absolute-git-dir)/pr-pollers-update.lock"; mkdir "$lock"
out="$(/bin/bash "$inst/build/poller.sh" 2>&1)" || fail "pass failed while locked: $out"
grep -q "another poller is updating" <<< "$out" || fail "locked pass did not report the lock"
[ "$(git -C "$inst" describe --tags)" = v0.11.0 ] || fail "updated while another poller held the lock"
[ -d "$lock" ] || fail "locked pass removed the other poller's lock"
# A lock left by a killed pass (older than 10 minutes) is cleared and the update proceeds.
touch -t "$(date -v-20M +%Y%m%d%H%M)" "$lock"
out="$(/bin/bash "$inst/build/poller.sh" 2>&1)" || fail "pass failed with stale lock: $out"
[ "$(git -C "$inst" describe --tags)" = v0.12.0 ] || fail "stale lock blocked the update"
[ ! -e "$lock" ] || fail "lock not released after update"

out="$(PR_POLLERS_UPDATED=1 /bin/bash "$inst/build/poller.sh" 2>&1)" || fail "pinned pass failed"
grep -q updated <<< "$out" && fail "pinned poller updated"
echo "ok"
