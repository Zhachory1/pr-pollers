---
name: pr-pollers
description: "Install, update, or remove three macOS launchd agents for the PR loop: build (draft PRs from issues assigned to the user and labeled agent-build), review (review PRs where the user is the assignee), and maintain (fix in-scope feedback and CI on the user's own PRs, file issues for the rest). Triggers: install pr-pollers, install the review/maintain/build poller, update pr-pollers, stop a poller, uninstall pr-pollers, poller broken."
---

# PR Pollers

Three pollers share one clone at `~/.local/share/pr-pollers`. Each has its own launchd job, log, and state, so the user can install or stop them separately.

| Poller | Job | Acts on | Does |
|---|---|---|---|
| `build` | `com.zhachory1.pr-pollers.build` | Open issues assigned to the user and labeled `agent-build` | Runs `build/skills/issue-builder/SKILL.md`: builds the smallest tested change on `agent/issue-<n>` and opens a **draft** PR that starts with `Closes #<n>`, or posts one question on the issue if it is unclear or too big. |
| `review` | `com.zhachory1.pr-pollers.review` | Open, non-draft PRs where the user is the assignee and not the author | Runs the autopraxis `pr-review` skill once per head SHA and posts the review. Skips SHAs the user already reviewed on GitHub. |
| `maintain` | `com.zhachory1.pr-pollers.maintain` | Open, non-draft PRs the user authored, when someone else leaves new feedback or CI fails at a new head SHA | Runs `maintain/skills/pr-review-handler/SKILL.md`: fixes in-scope feedback and PR-caused CI failures, pushes (never force), replies, resolves fixed threads, and files issues for out-of-scope work. Skips forks, pending CI, and PRs labeled `no-maintain`. No run cap. |

Every pass works in a fresh git worktree under `~/.local/state/pr-pollers/<poller>/worktrees`, removed afterwards, so it never touches the user's own checkouts. Pushes go over HTTPS with `gh` credentials, set only in the pollers' own clones. Failed runs are retried on the next pass. launchd never starts a second run of the same job while the first is still running. The three jobs share one clone, so only one of them updates it at a time; the others keep running their current version until the next pass.

Install only on macOS. When the user asks you to install the pollers, do these steps:

- **Choose pollers.** Ask which of `build`, `review`, and `maintain` to install. Default: all three.
- **Replace old pollers.** If any of `com.autopraxis.pr-review-poller`, `com.zhachory1.maintain-poller`, or `com.zhachory1.build-poller` is loaded (`launchctl print gui/$(id -u)/<label>` succeeds), follow the Uninstall section of that repo's `SKILL.md` (`~/.local/share/review-poller`, `maintain-poller`, or `build-poller`) first, so two jobs never act on the same PRs. Their handled-state files are not carried over: `review` and `build` re-check GitHub and skip work already done, but `maintain` handles the latest feedback on each PR once more.
- **Clone.** Run `git clone https://github.com/Zhachory1/pr-pollers ~/.local/share/pr-pollers`, then check out the newest release tag: `git -C ~/.local/share/pr-pollers checkout "$(git -C ~/.local/share/pr-pollers tag --sort=-v:refname | head -1)"`. If the folder already exists, follow Update instead. launchd runs the scripts from this path, so do not move it.
- **Check auth.** Confirm `gh auth status` succeeds and `jq` is installed. For `build` and `maintain`, the token must be able to push branches and open PRs in the user's repos. Everything posts as this GitHub account.
- **Check pr-review.** For `review` only: the poller tells the user's agent to use the `pr-review` skill from [autopraxis](https://github.com/Zhachory1/autopraxis). If the agent does not have it, install it with the `npx @zhachory1/autopraxis@latest install --target <target>` command from autopraxis `INSTALL.md` that matches the agent.
- **Agent command.** Ask the user for their agent command. It must run non-interactively and take the prompt as its last argument. For `review` it needs to run `gh`; for `build` and `maintain` it must also be allowed to edit files and run `git` and the repos' build and test commands, for example `claude -p --permission-mode acceptEdits --allowedTools "Bash(git:*)" "Bash(gh:*)" "Bash(npm test:*)"`. These agents run without supervision on input that anyone who can comment or file an issue controls, so prefer an allowlist over skipping permissions. Use exactly what the user gives you; do not guess. The same command can serve all three.
- **Claude trust.** If the agent command runs `claude` and `build` or `maintain` is selected, add `<key>PR_POLLERS_TRUST_CLAUDE</key><string>1</string>` to those plists' `EnvironmentVariables`. Claude Code ignores a repo's own `.claude/settings.json` (for example, its allowed test commands) until that folder is trusted, and the pollers' clones are new folders. With this set, the poller marks each clone under `~/.local/state/pr-pollers/<poller>/repos/` as trusted in `~/.claude.json` when it first uses it. Trusting a repo also enables that repo's Claude hooks, the same as opening it in Claude yourself; tell the user. Skip this step for other agents.
- **Interval.** Ask how often to poll (default 600 seconds).
- **Labels.** Tell the user:
  - `build` only builds issues assigned to them *and* labeled `agent-build`. The label must exist in each repo (`gh label create agent-build -R <owner/repo>`). Do not create it without asking.
  - Adding the `no-maintain` label to a PR makes `maintain` leave it alone.
- **Write plists.** For each selected poller `<name>`, write `~/Library/LaunchAgents/com.zhachory1.pr-pollers.<name>.plist` from the template. Replace each placeholder:
  - `__NAME__` with the poller name (`build`, `review`, or `maintain`);
  - `__AGENT_VAR__` with that poller's agent variable: `PR_BUILD_AGENT_CMD`, `PR_REVIEW_AGENT_CMD`, or `PR_MAINTAIN_AGENT_CMD`;
  - `__POLLER_PATH__` with the absolute path of `~/.local/share/pr-pollers/<name>/poller.sh`;
  - `__AGENT_CMD__` with the agent command;
  - `__TOOL_PATH__` with the directories that contain `gh`, `jq`, and the agent CLI (`dirname "$(command -v gh)"`, etc.);
  - `__HOME__` with the user's home directory.

  Replace only the placeholders. Afterwards no `__` placeholder may remain. XML-escape the values (`&` → `&amp;`, `<` → `&lt;`, `"` → `&quot;`). Set `StartInterval` to the chosen interval.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.zhachory1.pr-pollers.__NAME__</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>__POLLER_PATH__</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>__TOOL_PATH__:/usr/bin:/bin</string>
    <key>__AGENT_VAR__</key><string>__AGENT_CMD__</string>
  </dict>
  <key>StartInterval</key><integer>600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>__HOME__/Library/Logs/pr-pollers-__NAME__.log</string>
  <key>StandardErrorPath</key><string>__HOME__/Library/Logs/pr-pollers-__NAME__.log</string>
</dict></plist>
```

- **First-pass count.** The first pass acts on everything that already qualifies. Before loading, tell the user how many items each selected poller will pick up:
  - `build`: `gh search issues --assignee @me --label agent-build --state open --json number --jq length`
  - `review`: `gh search prs --assignee @me --state open --draft=false --json number --jq length`
  - `maintain`: `gh search prs --author @me --state open --draft=false --json number --jq length` (only those with outside feedback or failing CI will run)
- **Load.** For each plist, run `plutil -lint`, then `launchctl bootstrap gui/$(id -u) <plist>`. If the job is already loaded (update), run `launchctl bootout gui/$(id -u)/com.zhachory1.pr-pollers.<name>` first. Check `~/Library/Logs/pr-pollers-<name>.log` after the first run.
- **Tell the agent.** Add the block below to the user's global agent instructions so their interactive agent knows the pollers exist. Use the file that the user's agent reads: `~/.claude/CLAUDE.md` for Claude Code, `~/.codex/AGENTS.md` for Codex, otherwise `~/AGENTS.md`. If you are not sure, ask. Create the file if it does not exist. If the markers already exist, replace the text between them; do not add a second block. Keep only the lines for the pollers that are installed. Show the user the file path and the block before you write.

```markdown
<!-- pr-pollers:start -->
## Local PR pollers

launchd jobs on this Mac run my coding agent as me on a schedule (`~/.local/share/pr-pollers`). Runs they start name an issue or PR and a worktree in their prompt; do that work. The rules below apply only to work I ask for by hand.

- build (`com.zhachory1.pr-pollers.build`): opens a draft PR from `agent/issue-<n>` for each open issue assigned to me with the `agent-build` label, or asks one question on the issue. Do not start those issues by hand unless I ask; check for the branch or draft PR first. Draft PRs need my review before I mark them ready.
- review (`com.zhachory1.pr-pollers.review`): reviews each open, non-draft PR assigned to me once per head SHA, with the `pr-review` skill. Do not review those PRs again unless I ask.
- maintain (`com.zhachory1.pr-pollers.maintain`): on my own open PRs, fixes in-scope review feedback and CI and files issues for the rest, with `~/.local/share/pr-pollers/maintain/skills/pr-review-handler/SKILL.md`. Pull before editing my PR branches by hand. If I ask you to handle feedback on my PR, use that skill and its Scope Rule. The `no-maintain` label makes it skip a PR.
- Logs: `~/Library/Logs/pr-pollers-<name>.log`. State: `~/.local/state/pr-pollers/<name>/`.
- To stop, update, or debug the pollers, follow `~/.local/share/pr-pollers/SKILL.md`.
<!-- pr-pollers:end -->
```

- **Run again.** To make a poller act on an item again without a new trigger, delete that item's lines from `~/.local/state/pr-pollers/<name>/handled` (`review` uses `pr-review-seen` in the same folder). `review` still skips SHAs the user already reviewed on GitHub, and `build` still skips issues with an open PR.

## Update

Releases are git tags (`v1.0.0`, `v1.1.0`, ...). Install only tagged releases, never `main`. On every pass, each poller fetches tags and switches the shared clone to the newest `v*` tag, so script and skill fixes apply to all three without the user doing anything. If a new release changes this `SKILL.md`, the logs say `changes install steps; ask your agent to update the pr-pollers`. If local edits block the switch, the logs say `could not check out`. The steps below are for those cases and for rollback.

When the user asks you to update the pollers, do these steps:

- **Find versions.** Run `git -C ~/.local/share/pr-pollers fetch --tags`. The current version is `git -C ~/.local/share/pr-pollers describe --tags`. The newest is `git -C ~/.local/share/pr-pollers tag --sort=-v:refname | head -1`. If they match, tell the user they are up to date and stop.
- **Show changes.** Show the user the newest tag's message (`git -C ~/.local/share/pr-pollers tag -l --format='%(contents)' <new>`) and the files that changed (`git -C ~/.local/share/pr-pollers diff --stat <current> <new>`). Ask before you continue.
- **Check out.** Run `git -C ~/.local/share/pr-pollers checkout <new>`. If git refuses because of local changes, show them to the user and stop. Do not discard them.
- **Apply.** If `SKILL.md` did not change, you are done: launchd reads the scripts fresh on each run. If it changed, read it again and redo **Write plists**, **Load**, and **Tell the agent** from Install for the installed pollers. Keep the user's agent command, `PATH`, and interval from the current plists; ask only about new settings.
- **Check pr-review.** If the tag message says `review` needs a newer autopraxis, reinstall the `pr-review` skill with the matching `npx @zhachory1/autopraxis@latest install --target <target> --force` command.
- **Verify.** Check `~/Library/Logs/pr-pollers-<name>.log` after the next run.
- **Roll back or pin.** Auto-update moves back to the newest tag on the next pass. To stay on an older tag, add `<key>PR_POLLERS_UPDATED</key><string>1</string>` to **every** installed plist's `EnvironmentVariables` (one unpinned poller updates the shared clone for all), check out the tag, and redo **Load**. Remove the variable to resume auto-update.

## Uninstall

When the user asks you to stop, remove, or uninstall one or all pollers, or says one is broken, do these steps for each poller `<name>` they name (all three if they say all):

- **Unload.** Run `launchctl bootout gui/$(id -u)/com.zhachory1.pr-pollers.<name>`. This also stops a run in progress. If it fails with `3: No such process`, the job is already unloaded; continue.
- **Remove plist.** Delete `~/Library/LaunchAgents/com.zhachory1.pr-pollers.<name>.plist`, so the job does not load again at the next login.
- **Verify.** `launchctl print gui/$(id -u)/com.zhachory1.pr-pollers.<name>` must fail. If it still succeeds, report this to the user and stop.
- **Remove Claude trust.** If the plist had `PR_POLLERS_TRUST_CLAUDE`, remove the trust entries this poller added: `f=~/.claude.json; d="$(cd ~/.local/state/pr-pollers/<name>/repos 2>/dev/null && pwd -P)"; [ -n "$d" ] && tmp="$(mktemp "$f.XXXXXX")" && jq --arg p "$d/" '.projects |= with_entries(select(.key | startswith($p) | not))' "$f" > "$tmp" && mv "$tmp" "$f"`. Do this before deleting the state folder, which the command needs. Do not change other entries.
- **Update context.** In the agent instructions file you wrote at install (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`, or `~/AGENTS.md`), remove this poller's line from the pr-pollers block. If no pollers remain, delete the whole block: its start marker, end marker, and every line between them. Do not change other text in that file.
- **Ask before you delete data.** If a poller is broken, show the user the last 50 lines of `~/Library/Logs/pr-pollers-<name>.log` first. Then ask if they also want to delete the log and the state folder `~/.local/state/pr-pollers/<name>` (handled keys, cached repo clones, leftover worktrees). Delete only what they approve. When no pollers remain, also offer to delete the clone `~/.local/share/pr-pollers`.

Commits, reviews, replies, PRs, and issues already posted stay on GitHub. Uninstall does not remove the `pr-review` skill or autopraxis.
