---
name: pr-review-handler
description: "Maintain your own PR: classify and address review feedback (code changes, questions, nits), fix CI failures the PR caused, and file repo issues for feedback or failures outside the PR's scope. Distinguishes valid feedback from incorrect bot/human claims. Triggers: handle reviews, PR review, address feedback, reviewer comments, code review, review response, codex review, copilot review, address nits."
group: git-pr
---

# PR Review Handler

Monitor PR review comments, classify each piece of feedback (ACTIONABLE/QUESTION/NITS/APPROVAL/DISCUSSION), and take appropriate action: apply fixes, draft responses, or flag for human decision. Also fix CI failures the PR caused, and file an issue for anything outside the PR's scope.

## Scope Rule

Keep every change inside the PR's scope. Small fix pushes keep reviews short; every push triggers another review.

- **In scope:** the change serves the PR's stated goal (title, body, linked issue) and touches code the PR already changes or directly depends on.
- **Out of scope:** new features, refactors of code the PR does not touch, bugs that existed before the PR, cross-cutting changes, or a fix that would grow the PR by more than about 150 changed lines.
- **Unsure:** treat it as out of scope. A smaller PR is the safer mistake.

Out-of-scope feedback and CI failures go to **Out-of-Scope Issues** below. Do not change code for them.

**Not for:** reviewing others' PRs, creating PRs (use publish-branch), general GitHub ops (use `gh`).

## The Process

### Step 1: Fetch Review Comments

Retrieve all review comments for the PR:

```bash
gh pr view <PR_NUMBER> --json reviews,comments,reviewRequests
gh api --paginate repos/{owner}/{repo}/pulls/{pr}/comments
gh api --paginate repos/{owner}/{repo}/pulls/{pr}/reviews
```

Use `--paginate` on the REST calls so PRs with more than one page of inline comments are not truncated — otherwise later comments never participate in the thread join below and their threads stay unclassified.

If no PR number is provided, detect from the current branch:

```bash
gh pr view --json number,reviews,comments
```

Review threads are resolved via GraphQL (not exposed by `gh pr` flags). Fetch thread IDs alongside comments so each can be resolved after it is addressed. Include `fullDatabaseId` on each comment so REST review-comment IDs (from the calls above) map unambiguously to GraphQL thread IDs — matching on `body`/`path` alone is ambiguous when a comment is a reply or two comments share text. Paginate with `--paginate` so PRs with more than 100 threads are not silently truncated:

```bash
gh api graphql --paginate -f query='
  query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
    repository(owner:$owner,name:$repo){
      pullRequest(number:$pr){
        reviewThreads(first:100, after:$endCursor){
          pageInfo{ hasNextPage endCursor }
          nodes{
            id isResolved
            comments(first:100){ nodes{ fullDatabaseId body path line } }
          }
        }
      }
    }
  }' -f owner=OWNER -f repo=REPO -F pr=PR_NUMBER
```

Join each REST comment to its thread by `fullDatabaseId` (the REST comment `id`), then resolve that thread's `id`. Treat the THREAD as the unit of work: classify each unresolved thread exactly once, using its root review comment and replies as context. Do not classify replies (including your own) as separate work items.

### Step 2: Classify Each Unresolved Thread

Assign each unresolved thread to one category, using its root comment and replies as context:

| Category       | Description                    | Action                           |
| -------------- | ------------------------------ | -------------------------------- |
| **ACTIONABLE** | Code change requested          | Apply fix, run tests, commit     |
| **QUESTION**   | Reviewer asks a question       | Draft response with code context |
| **NITS**       | Style or formatting suggestion | Auto-fix, batch into one commit  |
| **APPROVAL**   | Approval or positive feedback  | No action needed                 |
| **DISCUSSION** | Requires human judgment        | Flag for user decision           |
| **OUT_OF_SCOPE** | Valid, but outside the PR's scope (see Scope Rule) | File or link an issue; reply with the link |

**Classification signals:**

- "Please rename..." / "Can you change..." / "This should be..." → ACTIONABLE
- "Why did you..." / "What happens if..." / "Can you explain..." → QUESTION
- "Nit:" / "Minor:" / "Style:" / formatting suggestions → NITS
- "LGTM" / "Looks good" / approval → APPROVAL
- Architecture debates / trade-off discussions → DISCUSSION
- "While you're here..." / "We should also..." / "Follow-up:" / a request that fails the Scope Rule → OUT_OF_SCOPE

### Step 3: Present Classification Summary

Show one row per unresolved thread with its classification:

| #   | Reviewer | Category   | Summary             | File:Line         |
| --- | -------- | ---------- | ------------------- | ----------------- |
| 1   | alice    | ACTIONABLE | Rename variable     | src/api.ts:42     |
| 2   | bob      | QUESTION   | Why async here?     | src/service.go:88 |
| 3   | alice    | NITS       | Trailing whitespace | src/util.py:15    |

Interactive mode: ask the user to confirm classifications before proceeding.

Unattended scheduler mode: if the caller explicitly says the run is approved
for unattended/automatic/hourly PR maintenance, do **not** stop for human
classification confirmation. Default to APPLYING ACTIONABLE and NITS fixes you
can make and validate with tests — do not defer a clear, well-specified fix to a
human just because it touches code. Flag for human decision ONLY when a fix
needs a judgment call the reviewer did not settle (ambiguous/underspecified with
more than one reasonable implementation, public API/contract/security/auth/data
change, large or cross-cutting refactor, or anything you cannot validate). If
the caller also explicitly enables full reply autonomy, post grounded replies to
QUESTION and DISCUSSION items and resolve their threads; do not invent facts or
expand code-change scope to answer them. Without full reply autonomy, post one
grounded reply to each QUESTION and a one-line "needs the author" reply to each
DISCUSSION, and leave both open. OUT_OF_SCOPE threads are never resolved in any mode.

### Step 4: Address Threads by Category

**ACTIONABLE threads:**

1. Read the referenced file and line
2. Understand the requested change in context
3. Apply the change
4. Run related tests to verify no regressions
5. Commit: `fix(review): address <reviewer> feedback - <summary>`

Push and verify (Step 5) before replying or resolving — do not reply to or resolve a thread whose fixing commit is not yet on the remote.

**QUESTION threads:**

1. Analyze the code context around the referenced line
2. Draft a response explaining the design decision or rationale
3. Interactive mode: present the draft to the user for approval before posting
4. Unattended full-reply-autonomy mode: post the grounded response without stopping
5. Resolve the thread after the response posts successfully
6. Unattended mode without full reply autonomy: post one grounded reply and leave the thread open

**NITS threads:**

1. Apply all nit fixes (formatting, naming, whitespace)
2. Batch into a single commit: `style: address review nits`

Push and verify (Step 5) before replying to or resolving the nit threads.

**OUT_OF_SCOPE threads:**

1. Follow **Out-of-Scope Issues** below to find or create the issue.
2. Reply once with the issue link and one line on why it is outside this PR.
3. Do not resolve the thread. The reviewer decides whether the deferral is acceptable.

**DISCUSSION threads:**

1. Summarize the discussion thread and inspect the relevant code/history
2. Interactive mode: present options and wait for the user before responding
3. Unattended full-reply-autonomy mode: choose and post the best grounded response without stopping;
   do not make higher-risk code changes merely to close the discussion
4. Resolve the thread after the response posts successfully
5. Unattended mode without full reply autonomy: post one short reply saying the decision needs the author, and leave the thread open

### Step 4b: Fix CI

Read the PR's checks (`gh pr checks <PR> --json name,state,link,workflow`). For each failed check:

1. Read the failure. For GitHub Actions use `gh run view <run-id> --log-failed`. For other CI (Buildkite, etc.) use `link` and any CI tools you have.
2. Decide the cause:
   - **Caused by the PR's diff** (compile error, failing test the PR touched or broke, lint on changed lines): fix it like an ACTIONABLE thread and commit `fix(ci): <summary>`.
   - **Flaky** (passes on retry, timing/network error, unrelated test that passes on the base branch): on GitHub Actions only, run `gh run rerun <run-id> --failed` once per head SHA. Do not rerun other CI systems.
   - **Not caused by the PR** (also fails on the base branch, infrastructure, expired credentials, an unrelated test): do not change code. File or link an issue (see **Out-of-Scope Issues**) and post one PR comment with the check name and issue link.
3. If you cannot tell, treat it as not caused by the PR.

Run the related tests locally before pushing a CI fix. Never disable, skip, or weaken a test to make CI pass.

### Out-of-Scope Issues

1. Search first: `gh issue list -R <owner/repo> --state open --search "<key terms>"`. If a matching issue exists, use it and do not create another.
2. Otherwise create one with `gh issue create -R <owner/repo> --title "<short problem>" --body-file <file>`, where `<file>` is a scratch file (see **Scratch files**). The body says what was found, links the PR and the review comment or check run, and states why it is outside the PR.
3. Add the label `from-review` only if the repo already has it (`gh label list -R <owner/repo>`). Do not create labels.
4. If issues are disabled or creation fails, put the same content in the thread reply or PR comment instead, and report it.

### Scratch files

Write issue bodies, reply drafts, and other temporary files in `.maintain-scratch/` at the root of the working copy (create it with `mkdir -p`). Never write to `/tmp` or other paths outside the working copy; you may not be allowed to delete them there. Never commit scratch files: check `git status` before each commit and do not stage `.maintain-scratch/`. Delete them when done with `command rm -rf .maintain-scratch`. The `command` prefix skips shell aliases, such as an `rm` that asks for confirmation and does nothing when no one answers.

### Step 5: Push First, Then Reply and Resolve

Push the tested commits and confirm the push succeeded **before** replying to or resolving any thread. If the push is rejected (auth, connectivity, non-fast-forward), stop and fix it — never reply to or resolve a thread whose commit reviewers cannot see.

```bash
git push
```

Only after the push lands, reply to each addressed thread, then resolve it. Post at most ONE new reply per unresolved thread per run. Immediately record the thread ID after posting so later steps cannot reply to it again; re-fetch before posting if the run has revisited the thread. Resolve every addressed ACTIONABLE/NITS thread, plus QUESTION/DISCUSSION threads whose reply was approved interactively or posted under explicit unattended full-reply-autonomy, using the thread `id` fetched in Step 1:

```bash
gh api graphql -f query='
  mutation($threadId:ID!){
    resolveReviewThread(input:{threadId:$threadId}){
      thread{ id isResolved }
    }
  }' -f threadId=THREAD_ID
```

In interactive mode, do not resolve QUESTION/DISCUSSION threads until the user approves the reply. In explicit unattended full-reply-autonomy mode, the caller's approval covers both posting the grounded reply and resolving its thread.

Confirm each addressed thread returned `isResolved: true` from the mutation, then present a summary of actions taken.

**Final reconciliation (do this once, at the end, before reporting).** Per-mutation confirmation is not sufficient on its own — a thread can be silently missed if classification or addressing skipped it, or a mutation can no-op on a stale/mis-mapped thread id. Re-run the Step 1 GraphQL query to re-fetch every review thread's `id`/`isResolved`, then for each thread you addressed this run (fix pushed + replied, or grounded reply posted) assert `isResolved:true`. Retry `resolveReviewThread` once for any addressed thread still showing `false`, then re-verify. Report the final tally: threads addressed, threads resolved, and any addressed-but-still-unresolved thread with its id and the mutation error. An addressed thread must never be left silently unresolved.

If files were edited, do not finish with only local uncommitted work. The final
state must be one of:

1. validated fixes committed, pushed, replied to, and resolved;
2. no local diff because validation failed or scope was unsafe (revert your
   attempted changes before reporting); or
3. not pushed because the branch was not pushable, the head moved, a conflict
   remained, or validation failed after edits. In this case, do not reply to or
   resolve comments as fixed, and report the exact blocker.

## Constraints

- **DO** classify each unresolved thread exactly once before taking any action
- **DO** confirm classifications with the user before proceeding in interactive mode
- **DO** proceed without confirmation only when the caller explicitly grants unattended/automatic PR-maintenance mode
- **DO** run tests after applying ACTIONABLE changes
- **DO** get user approval before posting QUESTION responses in interactive mode; explicit unattended full-reply-autonomy mode is approval
- **DO** batch NITS into a single commit
- **DO** push the fixing commit and confirm it landed before replying to or resolving its thread
- **DO** resolve each thread after it is addressed (reply is not enough)
- **DO** process each unresolved thread once and post at most one new reply to it per run
- **DO** verify addressed threads show `isResolved: true` before reporting
- **DO** run a final reconciliation sweep: re-fetch all threads and confirm every addressed thread is `isResolved: true`, retrying once and reporting any that are not
- **DO** resolve addressed threads uniformly — never resolve some handled threads and leave others in the same PR
- **DO** end with no local diff, or with validated fixes committed+pushed+replied+resolved
- **DO NOT** leave validated local fixes uncommitted or unpushed
- **DO NOT** auto-respond to QUESTION/DISCUSSION unless the caller explicitly enables full reply autonomy
- **DO NOT** reply to or resolve a thread whose required fixing commit is not yet pushed
- **DO NOT** dismiss review comments without addressing them
- **DO** keep every code change inside the Scope Rule; file an issue for the rest
- **DO** search for an existing issue before creating one
- **DO NOT** resolve OUT_OF_SCOPE threads; the reviewer decides
- **DO NOT** change code for CI failures the PR did not cause
- **DO NOT** disable, skip, or weaken tests to make CI pass
- **DO NOT** force-push
- **DO NOT** push changes without running tests first
- **DO NOT** post unapproved responses in interactive mode; unattended full-reply-autonomy mode is explicit approval

## Output Format

**Classification table:** One row per unresolved thread with reviewer, category,
summary, and file:line reference.

**Action log:** For each addressed thread: what was done, test results, commit
hash.

**CI log:** Each failed check, its cause (PR / flaky / not PR), and the action (fix commit, rerun, or issue link).

**Issues:** Each issue created or linked, with URL and source thread or check.

**Summary:** Threads received (by category), threads resolved count, threads
left open (with reason), pending user decisions, approval status, and final
worktree state (clean / pushed / blocked with reason).
