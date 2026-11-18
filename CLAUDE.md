# CLAUDE.md

Status line for Claude Code: a single bash script that reads the session JSON
on stdin and prints 2–5 lines (directory + git + pull request; model, context
bar, session cost, prompt cache and mode indicators; usage limits). User-facing docs, messages and code comments in `install.sh` and
`tests/` are in Russian; commit messages are in English.

## Commands

```bash
make check       # shellcheck + shfmt + tests — run before every commit
make test        # tests only (./tests/run.sh, no dependencies beyond bash/jq/git)
make fmt         # format with shfmt (settings come from .editorconfig)
make hooks       # enable the Conventional Commits commit-msg hook
```

Without `make`: `shellcheck <files>`, `shfmt -d <files>`, `./tests/run.sh`.
The file list is `SHELL_FILES` in the Makefile.

Try the script by hand:

```bash
echo '{"workspace":{"current_dir":"'"$PWD"'"},"context_window":{"used_percentage":25}}' | ./statusline.sh
```

## Layout

- `statusline.sh` — the product. `read_input` (one jq call) → `read_git` (one
  `git status --porcelain=v2`) → `render_*` → `main`. Holds `VERSION`.
- `install.sh` — copies the script into the Claude config dir and merges the
  `statusLine` key into `settings.json`; `--uninstall` reverses it.
- `tests/run.sh` — black-box tests for both scripts.
- `.githooks/commit-msg`, `.github/workflows/` — commit lint, CI, release.

## Rules for statusline.sh

- **It runs after every assistant message, so forks are the cost.** The
  baseline is one `jq` and two `git` processes; times are formatted with
  `format_time`, which needs no process on bash 4.2+. Helpers return through
  `REPLY` instead of `$(...)`. Do not add a subprocess per field.
- The git cache (`STATUSLINE_GIT_CACHE`) is read with `read` and validated,
  never evaluated; a new git field must be added to `reset_git`,
  `load_git_cache` and `save_git_cache` together, in the same order.
- **Every input field is optional.** Fields are absent or `null` before the
  first API response; the script must exit 0 and print something sensible for
  `{}` and for invalid JSON. Add new fields to the jq program in `read_input`
  through the `int` / `str` / `text` filters: `text` for anything displayed
  as free text (it replaces control characters), `str` for values that are
  only compared or validated before use.
- **Check the schema before touching fields:**
  https://code.claude.com/docs/en/statusline#available-data. It changes;
  `rate_limits.seven_day_sonnet` was removed here because it is not in it.
- **Never put data in a printf format string** and never use `printf %b` /
  `echo -e` on output: paths, branch names and commit subjects are untrusted.
  Colors are real escape bytes (`$'\033'`), printed with `%s`.
- **Portability:** bash 3.2 (macOS system bash) and both GNU and BSD
  userlands. No associative arrays, `${var,,}`, `mapfile`, or GNU-only flags
  without a BSD fallback. Newer-bash features are allowed only behind a
  version check with a 3.2 fallback, like `printf '%(…)T'` in `format_time`;
  keep a test that forces the fallback (`_STATUSLINE_FORCE_DATE=1`), because
  the macOS job is the only place the 3.2 path runs naturally.
- **Lines must fit `COLUMNS`.** Line 1 degrades through the levels in
  `render_location`; line 2 is the `SEGMENTS` array, most important first,
  and `join_fit` drops from the end. Add a new line-2 item as a segment in
  priority order, never by appending to an existing one.
- All color variables must be cleared in the `NO_COLOR` block.
- **Options are `STATUSLINE_*` environment variables**, validated in the
  configuration block; an invalid value silently keeps the default. A new
  segment gets a name for `STATUSLINE_HIDE` (checked with `shown <name>`) and
  a row in the README tables. Defaults must reproduce the previous output.

## Workflow

- **GitHub Issues track all work.** Before starting, find the issue
  (`gh issue list`, `gh issue view <n>`) or create one (`gh issue create`) —
  bugs, features and chores alike. Name the branch after it
  (`feature/<n>-<short-name>`, `hotfix/X.Y.Z` for a released bug) and end the
  commit or PR body with `Closes #<n>` (or `Refs #<n>` if it only partly
  addresses it). Follow-up work you notice but don't do goes into a new issue,
  not a TODO comment.
- **Every branch is merged through a pull request.** No local merges into
  `develop` or `main`, and no direct pushes to them — this covers feature,
  release and hotfix branches alike. The flow is: issue → branch → push →
  `gh pr create --base develop` → wait for CI (`gh pr checks --watch`) →
  `gh pr merge --merge --delete-branch`. Always a merge commit, never squash
  or rebase: Gitflow history keeps the branch visible. One PR per issue; fill
  in the PR template. `Closes #<n>` only auto-closes on merges into `main`,
  so after a PR lands in `develop`, close the issue yourself with a comment
  pointing at the PR.
- **`main` and `develop` are protected on GitHub**, admins included: a direct
  push is rejected with `GH006`, force pushes and deletion are off, and only
  merge commits are allowed. A rejection means the change needs a PR — never
  disable or loosen the protection to get something through; ask the user.
  Tags are not protected, so the release tag is still pushed directly.
- **Required checks are matched by job name:** `lint`,
  `test (ubuntu-latest, bash)`, `test (macos-latest, /bin/bash)`, `commits`.
  Renaming a CI job or changing the test matrix leaves every PR waiting on a
  check that no longer exists. Change the names in the same PR as the
  protection settings (`gh api repos/{owner}/{repo}/branches/<branch>/protection`),
  for both branches, and tell the user.
- **Gitflow.** Branch `feature/<n>-<name>` from `develop`. Releases go
  through `release/X.Y.Z`, hotfixes through `hotfix/X.Y.Z` from `main`; each
  of those needs two PRs, one into `main` and one into `develop`. The exact
  release steps are in CONTRIBUTING.md.
- **Conventional Commits**, enforced by the hook and CI:
  `type(scope): description` — types `feat fix docs refactor perf test build ci
  chore revert`, scopes `statusline install release`, subject ≤ 72 chars, no
  trailing period.
- **SemVer.** `VERSION` in `statusline.sh` is the single source of truth and a
  test checks it against the newest `CHANGELOG.md` section. Only bump it on a
  release branch.
- **Merge only when CI is green.** The macOS job runs the system bash 3.2,
  which cannot be reproduced on Linux, so local checks are not enough. In
  tests, build JSON with
  `printf` and a single-quoted format — `\"` inside `"$(...)"` is parsed
  differently by bash 3.2.
- A behavior change needs a test in `tests/run.sh` and a line under
  `[Unreleased]` in `CHANGELOG.md` (Russian, Keep a Changelog format).
- Pushing feature branches, opening and merging their PRs and closing their
  issues is part of doing the work. Do not tag or publish a release without
  being asked.
