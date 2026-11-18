# CLAUDE.md

Status line for Claude Code: a single bash script that reads the session JSON
on stdin and prints 2–5 lines (directory + git, model + context bar, usage
limits). User-facing docs, messages and code comments in `install.sh` and
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

- **It runs after every assistant message, so forks are the cost.** Keep it to
  one `jq` and two `git` processes. Helpers return through `REPLY` instead of
  `$(...)`. Do not add a subprocess per field.
- **Every input field is optional.** Fields are absent or `null` before the
  first API response; the script must exit 0 and print something sensible for
  `{}` and for invalid JSON. Add new fields to the jq program in `read_input`
  through the `int` / `str` filters.
- **Check the schema before touching fields:**
  https://code.claude.com/docs/en/statusline#available-data. It changes;
  `rate_limits.seven_day_sonnet` was removed here because it is not in it.
- **Never put data in a printf format string** and never use `printf %b` /
  `echo -e` on output: paths, branch names and commit subjects are untrusted.
  Colors are real escape bytes (`$'\033'`), printed with `%s`.
- **Portability:** bash 3.2 (macOS system bash) and both GNU and BSD
  userlands. No associative arrays, `${var,,}`, `mapfile`, `printf '%(…)T'`,
  or GNU-only flags without a BSD fallback.
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
- **Gitflow.** Branch `feature/<name>` from `develop`, merge back with
  `--no-ff`. Never commit directly to `main` or `develop`. Releases go through
  `release/X.Y.Z`, hotfixes through `hotfix/X.Y.Z` from `main`. The exact
  release commands are in CONTRIBUTING.md.
- **Conventional Commits**, enforced by the hook and CI:
  `type(scope): description` — types `feat fix docs refactor perf test build ci
  chore revert`, scopes `statusline install release`, subject ≤ 72 chars, no
  trailing period.
- **SemVer.** `VERSION` in `statusline.sh` is the single source of truth and a
  test checks it against the newest `CHANGELOG.md` section. Only bump it on a
  release branch.
- A behavior change needs a test in `tests/run.sh` and a line under
  `[Unreleased]` in `CHANGELOG.md` (Russian, Keep a Changelog format).
- Do not push, tag, or publish a release without being asked.
