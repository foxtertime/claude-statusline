#!/usr/bin/env bash
# claude-statusline — status line for Claude Code.
#
# Reads the session JSON from stdin and prints:
#   1. directory │ git branch, working tree state, last commit
#   2. model (context size) (effort) │ context usage bar
#   3+ one row per usage limit reported by Claude Code: 5-hour, 7-day,
#      gateway spend limit
#
# Input schema: https://code.claude.com/docs/en/statusline#available-data
# Requires: bash 3.2+, jq. Optional: git.
#
# Configuration (environment variables, see README):
#   STATUSLINE_LANG       ru | en
#   STATUSLINE_BAR_WIDTH  5..60, default 20
#   STATUSLINE_WARN       percent where bars turn yellow, default 50
#   STATUSLINE_CRIT       percent where bars turn red, default 80
#   STATUSLINE_HIDE       comma-separated segments to hide
#   STATUSLINE_RESET      absolute | relative — how reset times are shown
#   STATUSLINE_GIT_CACHE  seconds to reuse git state for, default 0 (off)

set -u
shopt -s extglob # visible_len strips escape sequences with *(...)

VERSION="1.1.1"

SUBJECT_MAX=40
SESSION_MAX=30
BRANCH_MIN=8   # never truncate a branch name below this many characters
WIDTH_MARGIN=4 # columns left free for Claude Code's own padding
MONTHS_RU=("" "янв" "фев" "мар" "апр" "май" "июн" "июл" "авг" "сен" "окт" "ноя" "дек")
MONTHS_EN=("" "Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec")

# --- configuration ----------------------------------------------------------
# A bad value must never break the line: anything invalid keeps the default.

# is_int <value> — non-negative integer of at most four digits
is_int() {
    case $1 in
        '' | *[!0-9]* | ?????*) return 1 ;;
    esac
}

LANG_CODE=ru
case ${STATUSLINE_LANG:-} in
    ru | en) LANG_CODE=$STATUSLINE_LANG ;;
esac

BAR_WIDTH=20
if is_int "${STATUSLINE_BAR_WIDTH:-}" &&
    [ "$STATUSLINE_BAR_WIDTH" -ge 5 ] && [ "$STATUSLINE_BAR_WIDTH" -le 60 ]; then
    BAR_WIDTH=$STATUSLINE_BAR_WIDTH
fi

WARN_AT=50
CRIT_AT=80
is_int "${STATUSLINE_WARN:-}" && WARN_AT=$STATUSLINE_WARN
is_int "${STATUSLINE_CRIT:-}" && CRIT_AT=$STATUSLINE_CRIT
if [ "$WARN_AT" -gt "$CRIT_AT" ]; then
    WARN_AT=50
    CRIT_AT=80
fi

RESET_MODE=absolute
case ${STATUSLINE_RESET:-} in
    absolute | relative) RESET_MODE=$STATUSLINE_RESET ;;
esac

# Reusing git state only pays off in very large repositories, so it is opt-in.
GIT_CACHE_TTL=0
is_int "${STATUSLINE_GIT_CACHE:-}" && GIT_CACHE_TTL=$STATUSLINE_GIT_CACHE
GIT_CACHE_DIR="${XDG_CACHE_HOME:-${HOME:-/tmp}/.cache}/claude-statusline"

# Claude Code exports the terminal size; 0 means "unknown, do not fit".
MAX_WIDTH=0
if is_int "${COLUMNS:-}" && [ "$COLUMNS" -ge 20 ]; then
    MAX_WIDTH=$((COLUMNS - WIDTH_MARGIN))
fi

# Segments: git commit pr links worktree effort fast agent context tokens cost
#           cache vim session
#           limits current weekly spend
HIDE=",${STATUSLINE_HIDE:-},"
HIDE=${HIDE// /,}

# shown <segment>
shown() {
    case $HIDE in
        *",$1,"*) return 1 ;;
    esac
}

# --- colors -----------------------------------------------------------------

ESC=$'\033'
C_RESET="${ESC}[0m"
C_DIR="${ESC}[1;36m"
C_DIM="${ESC}[2;37m"
C_MODEL="${ESC}[1;35m"
C_TEXT="${ESC}[37m"
C_GREEN="${ESC}[32m"
C_YELLOW="${ESC}[33m"
C_RED="${ESC}[31m"
C_GREEN_B="${ESC}[1;32m"
C_YELLOW_B="${ESC}[1;33m"
C_RED_B="${ESC}[1;31m"
C_CYAN_B="${ESC}[1;36m"

# https://no-color.org
if [ -n "${NO_COLOR:-}" ]; then
    C_RESET="" C_DIR="" C_DIM="" C_MODEL="" C_TEXT=""
    C_GREEN="" C_YELLOW="" C_RED=""
    C_GREEN_B="" C_YELLOW_B="" C_RED_B="" C_CYAN_B=""
fi

SEP="${C_DIM} │ ${C_RESET}"

# OSC 8 hyperlinks follow the colors: off under NO_COLOR, or hidden as "links".
BEL=$'\a'
LINKS=1
if [ -n "${NO_COLOR:-}" ] || ! shown links; then
    LINKS=0
fi

# --- helpers ----------------------------------------------------------------
# Helpers return their result in REPLY to avoid a subshell per call: the
# script runs after every assistant message, so forks are the main cost.

# repeat <char> <count>
repeat() {
    local pad
    printf -v pad '%*s' "$2" ''
    REPLY=${pad// /$1}
}

# visible_len <string> — length as displayed, without colors and link targets
visible_len() {
    local plain=${1//$ESC\[*([0-9;])m/}
    plain=${plain//$ESC\]8;;*([!$BEL])$BEL/}
    REPLY=${#plain}
}

# link <url> <text> — text as an OSC 8 hyperlink; plain text if links are off
# or the URL is not http(s). Control characters are stripped from the URL so
# it cannot terminate the escape sequence early.
link() {
    local url=${1//[[:cntrl:]]/}
    REPLY=$2
    [ "$LINKS" -eq 1 ] || return 0
    case $url in
        https://* | http://*) REPLY="${ESC}]8;;${url}${BEL}${2}${ESC}]8;;${BEL}" ;;
    esac
}

# short_path <path> <keep> — "…/proj/app": the last <keep> components
short_path() {
    local head=$1 tail="" i
    for ((i = 0; i < $2; i++)); do
        [ "${head%/*}" != "$head" ] || break
        tail="/${head##*/}${tail}"
        head=${head%/*}
    done
    if [ -z "$head" ] || [ "$head" = "~" ]; then
        REPLY=$1
    else
        REPLY="…${tail}"
    fi
}

# level_color <percent> — green below WARN_AT, yellow below CRIT_AT, then red
level_color() {
    if [ "$1" -ge "$CRIT_AT" ]; then
        REPLY=$C_RED
    elif [ "$1" -ge "$WARN_AT" ]; then
        REPLY=$C_YELLOW
    else
        REPLY=$C_GREEN
    fi
}

# bar <percent> — colored bar of BAR_WIDTH cells
bar() {
    local pct=$1 filled color
    filled=$(((pct * BAR_WIDTH + 50) / 100))
    [ "$filled" -gt "$BAR_WIDTH" ] && filled=$BAR_WIDTH
    [ "$filled" -lt 0 ] && filled=0
    level_color "$pct"
    color=$REPLY
    repeat "━" "$filled"
    local full=$REPLY
    repeat "─" "$((BAR_WIDTH - filled))"
    REPLY="${color}${full}${C_DIM}${REPLY}${C_RESET}"
}

# fmt_tokens <count> — 950, 125K, 1M, 1.5M
fmt_tokens() {
    local n=$1
    if [ "$n" -ge 1000000 ]; then
        local frac=$(((n % 1000000) / 100000))
        REPLY="$((n / 1000000))"
        [ "$frac" -gt 0 ] && REPLY="${REPLY}.${frac}"
        REPLY="${REPLY}M"
    elif [ "$n" -ge 1000 ]; then
        REPLY="$((n / 1000))K"
    else
        REPLY="$n"
    fi
}

# fmt_duration <seconds> — "45s", "38m", "1h 5m", "3d 4h" (ru: "38 мин", "1 ч 5 мин")
fmt_duration() {
    local s=$1 d h m
    d=$((s / 86400)) h=$((s % 86400 / 3600)) m=$((s % 3600 / 60))
    if [ "$LANG_CODE" = ru ]; then
        if [ "$d" -gt 0 ]; then
            REPLY="$d д"
            [ "$h" -gt 0 ] && REPLY="$REPLY $h ч"
        elif [ "$h" -gt 0 ]; then
            REPLY="$h ч"
            [ "$m" -gt 0 ] && REPLY="$REPLY $m мин"
        elif [ "$m" -gt 0 ]; then
            REPLY="$m мин"
        else
            REPLY="$s с"
        fi
    else
        if [ "$d" -gt 0 ]; then
            REPLY="${d}d"
            [ "$h" -gt 0 ] && REPLY="$REPLY ${h}h"
        elif [ "$h" -gt 0 ]; then
            REPLY="${h}h"
            [ "$m" -gt 0 ] && REPLY="$REPLY ${m}m"
        elif [ "$m" -gt 0 ]; then
            REPLY="${m}m"
        else
            REPLY="${s}s"
        fi
    fi
}

# fmt_remaining <epoch> — "через 2 ч 10 мин" / "in 2h 10m"
fmt_remaining() {

    set_now
    local left=$(($1 - NOW))
    if [ "$left" -lt 60 ]; then
        if [ "$LANG_CODE" = ru ]; then REPLY="<1 мин"; else REPLY="<1m"; fi
    else
        fmt_duration "$left"
    fi
    if [ "$LANG_CODE" = ru ]; then REPLY="через $REPLY"; else REPLY="in $REPLY"; fi
}

# fmt_reset <epoch> — when a window resets. Absolute: "19:30" if today,
# otherwise "10 мар, 19:30" / "Mar 10, 19:30". Relative: see fmt_remaining.
fmt_reset() {
    if [ "$RESET_MODE" = relative ]; then
        fmt_remaining "$1"
        return
    fi
    local ts=$1 fmt='+%Y%m%d %d %m %H:%M' out ymd day mon hhmm
    REPLY=""
    # GNU date takes -d @epoch, BSD/macOS date takes -r epoch.
    out=$(date -d "@$ts" "$fmt" 2>/dev/null || date -r "$ts" "$fmt" 2>/dev/null) || return 0
    read -r ymd day mon hhmm <<<"$out"
    if [ "$ymd" = "$(date +%Y%m%d)" ]; then
        REPLY=$hhmm
    elif [ "$LANG_CODE" = ru ]; then
        REPLY="$((10#$day)) ${MONTHS_RU[$((10#$mon))]}, $hhmm"
    else
        REPLY="${MONTHS_EN[$((10#$mon))]} $((10#$day)), $hhmm"
    fi
}

# set_now — fill NOW with the current epoch, once per run.
# EPOCHSECONDS needs bash 5; older shells pay one fork.
NOW=""
set_now() {
    [ -n "$NOW" ] || NOW=${EPOCHSECONDS:-$(date +%s)}
}

# --- input ------------------------------------------------------------------

# Every field is optional: Claude Code omits or nulls most of them before the
# first API response. jq rounds the numbers so the rest is integer-only bash.
read_input() {
    cwd="" model="" effort=""
    ctx_pct="" ctx_used="" ctx_size=""
    five_pct="" five_reset="" week_pct="" week_reset=""
    spend_pct="" spend_reset="" spend_usd=""
    pr_number="" pr_url="" pr_state="" pr_kind=""
    cost_usd="" cost_secs="" lines_added="" lines_removed=""
    cache_state="" cache_hit="" cache_expires=""
    fast="" vim_mode="" agent="" session="" worktree=""
    session_id=""

    local assignments
    assignments=$(jq -r '
        def int: if type == "number" then round else "" end;
        def str: if type == "string" then . else "" end;
        # Free text shown as is: control characters would break the layout.
        def text: str | gsub("\\p{Cc}"; " ");
        def money:
            if type == "number" and . > 0
            then (. * 100 | round) as $cents
                | "\($cents / 100 | floor).\($cents % 100 + 100 | tostring | .[1:])"
            else "" end;
        (.context_window // {}) as $ctx
        | (.rate_limits // {}) as $rl
        | ($rl.spend_limit // {}) as $spend
        | @sh "cwd=\(.workspace.current_dir // .cwd | str)",
          @sh "model=\(.model.display_name | text)",
          @sh "effort=\(.effort.level | text)",
          @sh "fast=\(if .fast_mode == true then "1" else "" end)",
          @sh "vim_mode=\(.vim.mode | text)",
          @sh "agent=\(.agent.name | text)",
          @sh "session=\(.session_name | text)",
          @sh "session_id=\(.session_id | str)",
          @sh "worktree=\(.workspace.git_worktree // .worktree.name | text)",
          @sh "ctx_pct=\($ctx.used_percentage | int)",
          @sh "ctx_used=\($ctx.total_input_tokens | int)",
          @sh "ctx_size=\($ctx.context_window_size | int)",
          @sh "five_pct=\($rl.five_hour.used_percentage | int)",
          @sh "five_reset=\($rl.five_hour.resets_at | int)",
          @sh "week_pct=\($rl.seven_day.used_percentage | int)",
          @sh "week_reset=\($rl.seven_day.resets_at | int)",
          @sh "spend_pct=\($spend.used_percentage | int)",
          @sh "spend_reset=\($spend.resets_at | int)",
          @sh "spend_usd=\(
              if $spend.used_usd != null and $spend.limit_usd != null
              then "$\($spend.used_usd) / $\($spend.limit_usd)"
              else "" end)",
          @sh "pr_number=\(.pr.number | int)",
          @sh "pr_url=\(.pr.url | str)",
          @sh "pr_state=\(.pr.review_state | str)",
          @sh "pr_kind=\(.pr.kind | str)",
          @sh "cost_usd=\(.cost.total_cost_usd | money)",
          @sh "cost_secs=\(.cost.total_duration_ms | if type == "number" then . / 1000 | floor else "" end)",
          @sh "lines_added=\(.cost.total_lines_added | int)",
          @sh "lines_removed=\(.cost.total_lines_removed | int)",
          @sh "cache_state=\(
              if .prompt_cache.caching_observed != true then ""
              elif .prompt_cache.warm == true then "warm"
              else "cold" end)",
          @sh "cache_hit=\(.prompt_cache.hit_ratio | if type == "number" then . * 100 | round else "" end)",
          @sh "cache_expires=\(.prompt_cache.expires_at | int)"
    ' 2>/dev/null) || return 0
    # Safe: every value is quoted by jq's @sh.
    eval "$assignments"
}

# --- git --------------------------------------------------------------------

reset_git() {
    git_branch="" git_subject="" git_age=""
    git_staged=0 git_modified=0 git_untracked=0 git_conflicted=0
    git_ahead=0 git_behind=0 git_stash=0
}

# read_git — git state for cwd, from the cache when it is enabled and fresh
read_git() {
    reset_git
    shown git || return 0

    local cache=""
    if [ "$GIT_CACHE_TTL" -gt 0 ]; then
        # session_id becomes part of a file name: accept only a safe one.
        case $session_id in
            '' | *[!A-Za-z0-9_-]*) ;;
            *) cache="$GIT_CACHE_DIR/git-$session_id" ;;
        esac
    fi
    if [ -n "$cache" ]; then
        set_now
        load_git_cache "$cache" && return 0
        reset_git
    fi

    query_git
    [ -n "$cache" ] && save_git_cache "$cache"
    return 0
}

# The cache is one value per line: timestamp, directory, then the git state.
# It is read with `read`, never evaluated, and anything unexpected in it is
# treated as a miss.

# load_git_cache <file> — succeeds only on a fresh entry for the same cwd
load_git_cache() {
    local stamp dir n
    [ -r "$1" ] || return 1
    {
        IFS= read -r stamp && IFS= read -r dir &&
            IFS= read -r git_branch &&
            IFS= read -r git_staged && IFS= read -r git_modified &&
            IFS= read -r git_untracked && IFS= read -r git_conflicted &&
            IFS= read -r git_ahead && IFS= read -r git_behind &&
            IFS= read -r git_stash &&
            IFS= read -r git_age && IFS= read -r git_subject
    } <"$1" || return 1
    for n in "$stamp" "$git_staged" "$git_modified" "$git_untracked" \
        "$git_conflicted" "$git_ahead" "$git_behind" "$git_stash"; do
        case $n in
            '' | *[!0-9]*) return 1 ;;
        esac
    done
    [ "$dir" = "$cwd" ] && [ "$stamp" -le "$NOW" ] && [ $((NOW - stamp)) -lt "$GIT_CACHE_TTL" ]
}

# save_git_cache <file>
save_git_cache() {
    if [ ! -d "$GIT_CACHE_DIR" ]; then
        (umask 077 && mkdir -p "$GIT_CACHE_DIR") 2>/dev/null || return 0
    fi
    # First write of a session: sweep entries left by sessions long gone.
    [ -e "$1" ] || find "$GIT_CACHE_DIR" -name 'git-*' -mtime +7 -exec rm -f {} + 2>/dev/null
    printf '%s\n' "$NOW" "$cwd" "$git_branch" \
        "$git_staged" "$git_modified" "$git_untracked" "$git_conflicted" \
        "$git_ahead" "$git_behind" "$git_stash" \
        "$git_age" "$git_subject" 2>/dev/null >"$1"
}

# query_git — ask git: one status call, one log call
query_git() {
    [ -d "$cwd" ] || return 0

    # --no-optional-locks: never contend for index.lock with Claude's own git
    # commands running in the same repository.
    local status
    status=$(git --no-optional-locks -C "$cwd" status --porcelain=v2 --branch --show-stash 2>/dev/null) || return 0

    local line oid="" xy
    while IFS= read -r line; do
        case $line in
            "# branch.oid "*) oid=${line#\# branch.oid } ;;
            "# branch.head "*) git_branch=${line#\# branch.head } ;;
            "# branch.ab "*)
                line=${line#\# branch.ab +}
                git_ahead=${line%% *}
                git_behind=${line##*-}
                ;;
            "# stash "*) git_stash=${line#\# stash } ;;
            "u "*) git_conflicted=$((git_conflicted + 1)) ;;
            "? "*) git_untracked=$((git_untracked + 1)) ;;
            "1 "* | "2 "*)
                xy=${line:2:2}
                [ "${xy:0:1}" != "." ] && git_staged=$((git_staged + 1))
                [ "${xy:1:1}" != "." ] && git_modified=$((git_modified + 1))
                ;;
        esac
    done <<<"$status"

    [ "$git_branch" = "(detached)" ] && git_branch=${oid:0:7}

    shown commit || return 0
    local log
    log=$(git --no-optional-locks -C "$cwd" log -1 --format='%cr%x09%s' 2>/dev/null) || return 0
    git_age=${log%%$'\t'*}
    git_subject=${log#*$'\t'}
    if [ "${#git_subject}" -gt "$SUBJECT_MAX" ]; then
        git_subject="${git_subject:0:$SUBJECT_MAX}…"
    fi
}

# --- rendering --------------------------------------------------------------

# render_location <level> [overflow]
# Level 0 is the full line; each next level gives up something to save width:
#   1  drop the last commit
#   2  shorten the path to its last two components
#   3  shorten the path to its last component
#   4  truncate the branch name by <overflow> columns
render_location() {
    local level=$1 overflow=${2:-0}
    local dir=${cwd:-?} branch=$git_branch
    if [ -n "${HOME:-}" ]; then
        case $dir in
            "$HOME") dir="~" ;;
            "$HOME"/*) dir="~${dir#"$HOME"}" ;;
        esac
    fi
    if [ "$level" -ge 2 ]; then
        short_path "$dir" $((level >= 3 ? 1 : 2))
        dir=$REPLY
    fi
    if [ "$level" -ge 4 ]; then
        local keep=$((${#branch} - overflow - 1))
        [ "$keep" -lt "$BRANCH_MIN" ] && keep=$BRANCH_MIN
        [ "$keep" -lt "${#branch}" ] && branch="${branch:0:keep}…"
    fi
    local out="${C_DIR}${dir}${C_RESET}"
    if ! shown git; then
        REPLY=$out
        return
    fi
    out="${out}${SEP}"

    if [ -z "$git_branch" ]; then
        REPLY="${out}${C_DIM}[no git]${C_RESET}"
        return
    fi

    local color=$C_GREEN_B
    [ $((git_staged + git_modified)) -gt 0 ] && color=$C_YELLOW_B
    [ "$git_conflicted" -gt 0 ] && color=$C_RED_B
    out="${out}${color}${branch}${C_RESET}"

    local tree=""
    [ "$git_conflicted" -gt 0 ] && tree="${tree} ${C_RED_B}!${git_conflicted}${C_RESET}"
    [ "$git_staged" -gt 0 ] && tree="${tree} ${C_GREEN}+${git_staged}${C_RESET}"
    [ "$git_modified" -gt 0 ] && tree="${tree} ${C_YELLOW}~${git_modified}${C_RESET}"
    [ "$git_untracked" -gt 0 ] && tree="${tree} ${C_DIM}?${git_untracked}${C_RESET}"
    out="${out}${tree:- ${C_DIM}[clean]${C_RESET}}"

    [ "$git_ahead" -gt 0 ] && out="${out} ${C_CYAN_B}↑${git_ahead}${C_RESET}"
    [ "$git_behind" -gt 0 ] && out="${out} ${C_RED_B}↓${git_behind}${C_RESET}"
    [ "$git_stash" -gt 0 ] && out="${out} ${C_DIM}≡${git_stash}${C_RESET}"
    [ -n "$worktree" ] && shown worktree && out="${out} ${C_DIM}wt:${worktree}${C_RESET}"
    if [ -n "$pr_number" ] && shown pr; then
        render_pr
        out="${out} ${REPLY}"
    fi
    [ -n "$git_subject" ] && [ "$level" -lt 1 ] &&
        out="${out}${SEP}${C_DIM}${git_subject} · ${git_age}${C_RESET}"
    REPLY=$out
}

# render_pr — "#123 approved", colored by review state and linked to the PR.
# GitLab merge requests are written "!123".
render_pr() {
    local color=$C_CYAN_B label="#${pr_number}"
    [ "$pr_kind" = mr ] && label="!${pr_number}"
    case $pr_state in
        approved) color=$C_GREEN && label="${label} approved" ;;
        changes_requested) color=$C_RED && label="${label} changes" ;;
        pending) color=$C_YELLOW && label="${label} pending" ;;
        draft) color=$C_DIM && label="${label} draft" ;;
    esac
    link "$pr_url" "$label"
    REPLY="${color}${REPLY}${C_RESET}"
}

# fit_location — the fullest line 1 that fits MAX_WIDTH
fit_location() {
    local level line overflow=0
    for level in 0 1 2 3 4; do
        render_location "$level" "$overflow"
        [ "$MAX_WIDTH" -eq 0 ] && return
        line=$REPLY
        visible_len "$line"
        overflow=$((REPLY - MAX_WIDTH))
        [ "$overflow" -le 0 ] && break
    done
    REPLY=$line
}

# join_fit — join SEGMENTS with the separator, dropping segments from the end
# until the line fits MAX_WIDTH. The first segment always stays.
join_fit() {
    local count=${#SEGMENTS[@]} line i
    while :; do
        line=${SEGMENTS[0]}
        for ((i = 1; i < count; i++)); do
            line="${line}${SEP}${SEGMENTS[i]}"
        done
        if [ "$MAX_WIDTH" -eq 0 ] || [ "$count" -le 1 ]; then
            break
        fi
        visible_len "$line"
        [ "$REPLY" -le "$MAX_WIDTH" ] && break
        count=$((count - 1))
    done
    REPLY=$line
}

# render_model — fills SEGMENTS for line 2, most important first
render_model() {
    local out="${C_MODEL}${model:-?}"
    if [ -n "$ctx_size" ]; then
        fmt_tokens "$ctx_size"
        out="${out} (${REPLY})"
    fi
    [ -n "$effort" ] && shown effort && out="${out} (${effort})"
    out="${out}${C_RESET}"
    [ -n "$fast" ] && shown fast && out="${out} ${C_YELLOW_B}fast${C_RESET}"
    [ -n "$agent" ] && shown agent && out="${out} ${C_CYAN_B}@${agent}${C_RESET}"
    SEGMENTS=("$out")

    if [ -n "$ctx_pct" ] && shown context; then
        bar "$ctx_pct"
        out="${C_DIM}Ctx${C_RESET} ${REPLY} ${C_TEXT}${ctx_pct}%"
        if [ -n "$ctx_used" ] && [ -n "$ctx_size" ] && shown tokens; then
            fmt_tokens "$ctx_used"
            out="${out} (${REPLY} / "
            fmt_tokens "$ctx_size"
            out="${out}${REPLY})"
        fi
        SEGMENTS+=("${out}${C_RESET}")
    fi

    if shown cost; then
        render_cost
        [ -n "$REPLY" ] && SEGMENTS+=("$REPLY")
    fi

    if [ -n "$cache_state" ] && shown cache; then
        render_cache
        SEGMENTS+=("$REPLY")
    fi

    if [ -n "$vim_mode" ] && shown vim; then
        local color=$C_GREEN_B
        [ "$vim_mode" = NORMAL ] && color=$C_YELLOW_B
        SEGMENTS+=("${color}${vim_mode}${C_RESET}")
    fi

    if [ -n "$session" ] && shown session; then
        local name=$session
        [ "${#name}" -gt "$SESSION_MAX" ] && name="${name:0:SESSION_MAX}…"
        SEGMENTS+=("${C_DIM}${name}${C_RESET}")
    fi
}

# render_cache — "Cache 91% · 19:30" while the prompt cache is warm (hit ratio
# and when it goes cold), "Cache cold" once it has expired
render_cache() {
    if [ "$cache_state" = cold ]; then
        REPLY="${C_DIM}Cache${C_RESET} ${C_YELLOW}cold${C_RESET}"
        return
    fi
    local out="${C_DIM}Cache${C_RESET}"
    [ -n "$cache_hit" ] && out="${out} ${C_GREEN}${cache_hit}%${C_RESET}"
    if [ -n "$cache_expires" ]; then
        fmt_reset "$cache_expires"
        if [ -n "$REPLY" ]; then
            [ -n "$cache_hit" ] && out="${out}${C_DIM} ·${C_RESET}"
            out="${out} ${C_DIM}${REPLY}${C_RESET}"
        fi
    fi
    [ -z "${cache_hit}${cache_expires}" ] && out="${out} ${C_GREEN}warm${C_RESET}"
    REPLY=$out
}

# render_cost — "$1.24 · 38m · +156 −23"; empty when there is nothing to show
render_cost() {
    local out="" dot="${C_DIM} · ${C_RESET}"
    # The dollar figure is a list-price estimate; it means nothing on a
    # subscription, which is recognised by its rate-limit windows.
    if [ -n "$cost_usd" ] && [ -z "${five_pct}${week_pct}" ]; then
        out="${C_TEXT}\$${cost_usd}${C_RESET}"
    fi
    if [ "${cost_secs:-0}" -gt 0 ]; then
        fmt_duration "$cost_secs"
        out="${out:+${out}${dot}}${C_DIM}${REPLY}${C_RESET}"
    fi
    if [ $((${lines_added:-0} + ${lines_removed:-0})) -gt 0 ]; then
        out="${out:+${out}${dot}}${C_GREEN}+${lines_added:-0}${C_RESET} ${C_RED}−${lines_removed:-0}${C_RESET}"
    fi
    REPLY=$out
}

# render_limit <label> <percent> <reset epoch> [note]
render_limit() {
    local label=$1 pct=$2 reset=$3 note=${4:-} out
    bar "$pct"
    printf -v out '%s%-8s%s%s %s%s%%%s' "$C_DIM" "$label" "$C_RESET" "$REPLY" "$C_DIM" "$pct" "$C_RESET"
    if [ -n "$reset" ]; then
        fmt_reset "$reset"
        [ -n "$REPLY" ] && out="${out}  ${C_DIM}${REPLY}${C_RESET}"
    fi
    [ -n "$note" ] && out="${out}  ${C_DIM}${note}${C_RESET}"
    REPLY=$out
}

# --- main -------------------------------------------------------------------

main() {
    case ${1:-} in
        -v | --version)
            echo "claude-statusline $VERSION"
            return 0
            ;;
    esac

    if ! command -v jq >/dev/null 2>&1; then
        if [ "$LANG_CODE" = ru ]; then
            echo "claude-statusline: jq не найден"
        else
            echo "claude-statusline: jq not found"
        fi
        return 0
    fi

    read_input
    read_git

    fit_location
    printf '%s\n' "$REPLY"
    render_model
    join_fit
    printf '%s\n' "$REPLY"
    shown limits || return 0
    if [ -n "$five_pct" ] && shown current; then
        render_limit "Current" "$five_pct" "$five_reset"
        printf '%s\n' "$REPLY"
    fi
    if [ -n "$week_pct" ] && shown weekly; then
        render_limit "Weekly" "$week_pct" "$week_reset"
        printf '%s\n' "$REPLY"
    fi
    # Present only behind a Claude apps gateway with a spend limit.
    if [ -n "$spend_pct" ] && shown spend; then
        render_limit "Spend" "$spend_pct" "$spend_reset" "$spend_usd"
        printf '%s\n' "$REPLY"
    fi
}

main "$@"
