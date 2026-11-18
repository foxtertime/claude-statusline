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

set -u

VERSION="1.0.0"

BAR_WIDTH=20
SUBJECT_MAX=40
RU_MONTHS=("" "янв" "фев" "мар" "апр" "май" "июн" "июл" "авг" "сен" "окт" "ноя" "дек")

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

# --- helpers ----------------------------------------------------------------
# Helpers return their result in REPLY to avoid a subshell per call: the
# script runs after every assistant message, so forks are the main cost.

# repeat <char> <count>
repeat() {
    local pad
    printf -v pad '%*s' "$2" ''
    REPLY=${pad// /$1}
}

# level_color <percent> — green < 50, yellow < 80, red otherwise
level_color() {
    if [ "$1" -ge 80 ]; then
        REPLY=$C_RED
    elif [ "$1" -ge 50 ]; then
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

# fmt_reset <epoch> — "19:30" if today, otherwise "10 мар, 19:30"
fmt_reset() {
    local ts=$1 fmt='+%Y%m%d %d %m %H:%M' out ymd day mon hhmm
    REPLY=""
    # GNU date takes -d @epoch, BSD/macOS date takes -r epoch.
    out=$(date -d "@$ts" "$fmt" 2>/dev/null || date -r "$ts" "$fmt" 2>/dev/null) || return 0
    read -r ymd day mon hhmm <<<"$out"
    if [ "$ymd" = "$(date +%Y%m%d)" ]; then
        REPLY=$hhmm
    else
        REPLY="$((10#$day)) ${RU_MONTHS[$((10#$mon))]}, $hhmm"
    fi
}

# --- input ------------------------------------------------------------------

# Every field is optional: Claude Code omits or nulls most of them before the
# first API response. jq rounds the numbers so the rest is integer-only bash.
read_input() {
    cwd="" model="" effort=""
    ctx_pct="" ctx_used="" ctx_size=""
    five_pct="" five_reset="" week_pct="" week_reset=""
    spend_pct="" spend_reset="" spend_usd=""

    local assignments
    assignments=$(jq -r '
        def int: if type == "number" then round else "" end;
        def str: if type == "string" then . else "" end;
        (.context_window // {}) as $ctx
        | (.rate_limits // {}) as $rl
        | ($rl.spend_limit // {}) as $spend
        | @sh "cwd=\(.workspace.current_dir // .cwd | str)",
          @sh "model=\(.model.display_name | str)",
          @sh "effort=\(.effort.level | str)",
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
              else "" end)"
    ' 2>/dev/null) || return 0
    # Safe: every value is quoted by jq's @sh.
    eval "$assignments"
}

# --- git --------------------------------------------------------------------

read_git() {
    git_branch="" git_subject="" git_age=""
    git_staged=0 git_modified=0 git_untracked=0 git_conflicted=0
    git_ahead=0 git_behind=0 git_stash=0

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

    local log
    log=$(git --no-optional-locks -C "$cwd" log -1 --format='%cr%x09%s' 2>/dev/null) || return 0
    git_age=${log%%$'\t'*}
    git_subject=${log#*$'\t'}
    if [ "${#git_subject}" -gt "$SUBJECT_MAX" ]; then
        git_subject="${git_subject:0:$SUBJECT_MAX}…"
    fi
}

# --- rendering --------------------------------------------------------------

render_location() {
    local dir=${cwd:-?}
    if [ -n "${HOME:-}" ]; then
        case $dir in
            "$HOME") dir="~" ;;
            "$HOME"/*) dir="~${dir#"$HOME"}" ;;
        esac
    fi
    local out="${C_DIR}${dir}${C_RESET}${SEP}"

    if [ -z "$git_branch" ]; then
        REPLY="${out}${C_DIM}[no git]${C_RESET}"
        return
    fi

    local color=$C_GREEN_B
    [ $((git_staged + git_modified)) -gt 0 ] && color=$C_YELLOW_B
    [ "$git_conflicted" -gt 0 ] && color=$C_RED_B
    out="${out}${color}${git_branch}${C_RESET}"

    local tree=""
    [ "$git_conflicted" -gt 0 ] && tree="${tree} ${C_RED_B}!${git_conflicted}${C_RESET}"
    [ "$git_staged" -gt 0 ] && tree="${tree} ${C_GREEN}+${git_staged}${C_RESET}"
    [ "$git_modified" -gt 0 ] && tree="${tree} ${C_YELLOW}~${git_modified}${C_RESET}"
    [ "$git_untracked" -gt 0 ] && tree="${tree} ${C_DIM}?${git_untracked}${C_RESET}"
    out="${out}${tree:- ${C_DIM}[clean]${C_RESET}}"

    [ "$git_ahead" -gt 0 ] && out="${out} ${C_CYAN_B}↑${git_ahead}${C_RESET}"
    [ "$git_behind" -gt 0 ] && out="${out} ${C_RED_B}↓${git_behind}${C_RESET}"
    [ "$git_stash" -gt 0 ] && out="${out} ${C_DIM}≡${git_stash}${C_RESET}"
    [ -n "$git_subject" ] && out="${out}${SEP}${C_DIM}${git_subject} · ${git_age}${C_RESET}"
    REPLY=$out
}

render_model() {
    local out="${C_MODEL}${model:-?}"
    if [ -n "$ctx_size" ]; then
        fmt_tokens "$ctx_size"
        out="${out} (${REPLY})"
    fi
    [ -n "$effort" ] && out="${out} (${effort})"
    out="${out}${C_RESET}"

    if [ -n "$ctx_pct" ]; then
        bar "$ctx_pct"
        out="${out}${SEP}${C_DIM}Ctx${C_RESET} ${REPLY} ${C_TEXT}${ctx_pct}%"
        if [ -n "$ctx_used" ] && [ -n "$ctx_size" ]; then
            fmt_tokens "$ctx_used"
            out="${out} (${REPLY} / "
            fmt_tokens "$ctx_size"
            out="${out}${REPLY})"
        fi
        out="${out}${C_RESET}"
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
        echo "claude-statusline: jq не найден"
        return 0
    fi

    read_input
    read_git

    render_location
    printf '%s\n' "$REPLY"
    render_model
    printf '%s\n' "$REPLY"
    if [ -n "$five_pct" ]; then
        render_limit "Current" "$five_pct" "$five_reset"
        printf '%s\n' "$REPLY"
    fi
    if [ -n "$week_pct" ]; then
        render_limit "Weekly" "$week_pct" "$week_reset"
        printf '%s\n' "$REPLY"
    fi
    # Present only behind a Claude apps gateway with a spend limit.
    if [ -n "$spend_pct" ]; then
        render_limit "Spend" "$spend_pct" "$spend_reset" "$spend_usd"
        printf '%s\n' "$REPLY"
    fi
}

main "$@"
