# pr-pollers

Three macOS launchd agents for the PR loop. Each runs your own coding agent, under your own GitHub account, on a schedule.

| Poller | Acts on | Does |
|---|---|---|
| **build** | Issues assigned to you with the `agent-build` label | Builds the smallest tested change on `agent/issue-<n>` and opens a **draft** PR that says `Closes #<n>`, or asks one question on the issue if it is unclear or too big. |
| **review** | Non-draft PRs where you are the assignee | Reviews each new head SHA with the autopraxis [`pr-review`](https://github.com/Zhachory1/autopraxis) skill. |
| **maintain** | Your own non-draft PRs, after outside feedback or a CI failure | Fixes in-scope feedback and PR-caused CI failures, pushes, replies, resolves fixed threads, and files issues for anything out of scope. |

How they fit together:

1. Assign yourself an issue and add `agent-build`. A draft PR shows up.
2. Check the draft, then mark it ready. Nothing acts on a draft before that.
3. Add a teammate as assignee. Their review poller reviews it.
4. Your maintain poller handles the feedback and CI.
5. A human approves and merges. The pollers never merge.

## Install

Ask your coding agent:

> Install the pr-pollers from https://github.com/Zhachory1/pr-pollers by following its SKILL.md.

The agent clones this repo to `~/.local/share/pr-pollers`, asks which pollers you want, your agent command, and the poll interval, loads one LaunchAgent per poller, and adds a short note to your global agent instructions. Uninstall removes it.

## Operate

- Logs: `~/Library/Logs/pr-pollers-<name>.log`
- Skip a PR for maintain: add the `no-maintain` label.
- Update: automatic. Each pass switches to the newest release tag. If a release changes install steps, the log tells you to ask your agent to "update the pr-pollers".
- Stop: ask your agent to "uninstall the <name> poller", or "uninstall the pr-pollers" for all three.
- Test: `./test.sh` (needs `jq` and `git`)

## Layout

- `<name>/poller.sh`: one polling pass, run by launchd. Starts with a self-contained self-update block.
- `<name>/test.sh`: tests with a fake `gh` and a local bare repo standing in for GitHub.
- `maintain/skills/pr-review-handler`, `build/skills/issue-builder`: the bundled skills the agent follows.
- `lib.sh`: shared clone, worktree, Claude trust, and agent-run helpers.
- `SKILL.md`: install, update, and uninstall steps for the user's agent.

## Release (maintainer)

Installed pollers switch to a new `v*` tag on their next pass, so a pushed tag runs on every user's Mac within one poll interval, under their GitHub account, and can push branches and open PRs. Tag only what you would run yourself. To undo a bad release, push a newer tag with the fix.

```bash
./test.sh
git tag -a v1.1.0 -m "What changed and whether users must redo any install step"
git push origin v1.1.0
```

Replaces [review-poller](https://github.com/Zhachory1/review-poller), [maintain-poller](https://github.com/Zhachory1/maintain-poller), and [build-poller](https://github.com/Zhachory1/build-poller).
