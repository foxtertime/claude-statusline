#!/usr/bin/env bash
# claude-statusline — status line for Claude Code.
#
# Reads the session JSON from stdin and prints:
#   1. directory │ git branch, working tree state, worktree, pull request
#      │ last commit
#   2. model (context size) (effort) fast @agent │ context usage bar
#      │ session cost, duration, lines │ prompt cache │ vim mode │ session name
#   3+ one row per usage limit reported by Claude Code: 5-hour, 7-day,
#      gateway spend limit
# Everything but the directory and the model appears only when Claude Code
# sends the data. Lines 1 and 2 shrink to fit COLUMNS.
#
# Input schema: https://code.claude.com/docs/en/statusline#available-data
# Requires: bash 3.2+, jq. Optional: git.
#
# Configuration (environment variables, see README):
#   STATUSLINE_LANG       ru | en, default from the locale
#   STATUSLINE_BAR_WIDTH  5..60, default 20
#   STATUSLINE_WARN       percent where bars turn yellow, default 50
#   STATUSLINE_CRIT       percent where bars turn red, default 80
#   STATUSLINE_HIDE       comma-separated segments to hide
#   STATUSLINE_RESET      absolute | relative — how reset times are shown
#   STATUSLINE_GIT_CACHE  seconds to reuse git state for, default 0 (off)
#   STATUSLINE_THEME      dark | light, default dark
#   STATUSLINE_COLOR_<ROLE>  SGR code overriding one role, e.g. "1;34"
#   STATUSLINE_ASCII      1 to draw with ASCII characters only
#   STATUSLINE_PADDING    the statusLine.padding value from settings.json
#   STATUSLINE_LAYOUT     order of line-2 segments, "/" starts a new line;
#                         or "compact" for a single line

set -u

VERSION="1.4.0"

SUBJECT_MAX=40
SESSION_MAX=30
BRANCH_MIN=8 # never truncate a branch name below this many characters
# Claude Code shows COLUMNS - 4 - 2 * padding columns of a status line and
# cuts longer lines with an ellipsis (measured on Claude Code 2.1.327 at
# widths 80, 100 and 130 with padding 0-3).
WIDTH_MARGIN=4
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

# Language: explicit setting first, then the locale that governs dates, with
# the usual precedence LC_ALL > LC_TIME > LANG. Russian for ru*, else English.
LANG_CODE=en
case ${STATUSLINE_LANG:-} in
    ru | en) LANG_CODE=$STATUSLINE_LANG ;;
    *)
        case ${LC_ALL:-${LC_TIME:-${LANG:-}}} in
            ru | ru[_.@]*) LANG_CODE=ru ;;
        esac
        ;;
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

# statusLine.padding is not part of the input, so it is passed as an option.
PADDING=0
if is_int "${STATUSLINE_PADDING:-}" && [ "$STATUSLINE_PADDING" -le 40 ]; then
    PADDING=$STATUSLINE_PADDING
fi

# Claude Code exports the terminal size; 0 means "unknown, do not fit".
MAX_WIDTH=0
if is_int "${COLUMNS:-}" && [ "$COLUMNS" -ge 20 ]; then
    MAX_WIDTH=$((COLUMNS - WIDTH_MARGIN - 2 * PADDING))
    [ "$MAX_WIDTH" -lt 10 ] && MAX_WIDTH=10
fi

# Layout. Line-2 segments in the order given; "/" moves the following ones to
# a line of their own; segments not named follow in default order on the last
# line; unknown names are ignored. "compact" prints a single line.
LINE2_SEGMENTS="context cost cache vim session"
COMPACT=0
LAYOUT_GROUPS=("$LINE2_SEGMENTS")
parse_layout() {
    local spec=${STATUSLINE_LAYOUT:-} group name seen=" " groups=() list rest
    [ -n "$spec" ] || return 0
    if [ "$spec" = compact ]; then
        COMPACT=1
        return 0
    fi
    spec=${spec// /,}
    while :; do
        group=${spec%%/*}
        list=""
        # Word splitting only: a name like "*" must not match files.
        set -f
        for name in ${group//,/ }; do
            case " $LINE2_SEGMENTS " in *" $name "*) ;; *) continue ;; esac
            case $seen in *" $name "*) continue ;; esac
            seen="${seen}${name} "
            list="${list:+$list }$name"
        done
        set +f
        [ -n "$list" ] && groups+=("$list")
        [ "$group" = "$spec" ] && break
        spec=${spec#*/}
    done
    rest=""
    for name in $LINE2_SEGMENTS; do
        case $seen in *" $name "*) ;; *) rest="${rest:+$rest }$name" ;; esac
    done
    if [ "${#groups[@]}" -eq 0 ]; then
        groups=("$rest")
    elif [ -n "$rest" ]; then
        groups[${#groups[@]} - 1]="${groups[${#groups[@]} - 1]} $rest"
    fi
    LAYOUT_GROUPS=("${groups[@]}")
}
parse_layout

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

# --- labels -----------------------------------------------------------------

if [ "$LANG_CODE" = ru ]; then
    L_CTX="Контекст" L_CACHE="Кэш" L_COLD="остыл" L_WARM="тёплый"
    L_FAST="быстро" L_CLEAN="[чисто]" L_NO_GIT="[нет git]"
    L_CURRENT="Сейчас" L_WEEKLY="Неделя" L_SPEND="Расход"
    L_APPROVED="одобрен" L_CHANGES="правки" L_PENDING="ждёт" L_DRAFT="черновик"
    L_5H="5ч" L_7D="7д"
else
    L_CTX="Ctx" L_CACHE="Cache" L_COLD="cold" L_WARM="warm"
    L_FAST="fast" L_CLEAN="[clean]" L_NO_GIT="[no git]"
    L_CURRENT="Current" L_WEEKLY="Weekly" L_SPEND="Spend"
    L_APPROVED="approved" L_CHANGES="changes" L_PENDING="pending" L_DRAFT="draft"
    L_5H="5h" L_7D="7d"
fi

# Limit labels are padded to the longest one plus a space.
LIMIT_LABEL_WIDTH=${#L_CURRENT}
[ "${#L_WEEKLY}" -gt "$LIMIT_LABEL_WIDTH" ] && LIMIT_LABEL_WIDTH=${#L_WEEKLY}
[ "${#L_SPEND}" -gt "$LIMIT_LABEL_WIDTH" ] && LIMIT_LABEL_WIDTH=${#L_SPEND}
LIMIT_LABEL_WIDTH=$((LIMIT_LABEL_WIDTH + 1))

# --- glyphs -----------------------------------------------------------------

if [ -n "${STATUSLINE_ASCII:-}" ] && [ "$STATUSLINE_ASCII" != 0 ]; then
    G_FULL="#" G_EMPTY="-" G_SEP="|" G_AHEAD="^" G_BEHIND="v" G_STASH="="
    G_ELLIPSIS="..." G_DOT="-" G_MINUS="-"
else
    G_FULL="━" G_EMPTY="─" G_SEP="│" G_AHEAD="↑" G_BEHIND="↓" G_STASH="≡"
    G_ELLIPSIS="…" G_DOT="·" G_MINUS="−"
fi

# --- colors -----------------------------------------------------------------
# Each role is an SGR code. OK, WARN and CRIT also have a bold variant, used
# for the branch name and mode markers.

ESC=$'\033'
R_DIR="1;36" R_MUTED="2;37" R_MODEL="1;35" R_TEXT="37"
R_OK="32" R_WARN="33" R_CRIT="31" R_ACCENT="1;36"

# Dim white is unreadable on a light background.
if [ "${STATUSLINE_THEME:-}" = light ]; then
    R_MUTED="90" R_TEXT="30"
fi

# STATUSLINE_COLOR_<ROLE> overrides one role; only digits and ";" are accepted.
for role in DIR MUTED MODEL TEXT OK WARN CRIT ACCENT; do
    var="STATUSLINE_COLOR_$role"
    value=${!var:-}
    case $value in
        '' | *[!0-9\;]* | ????????????????*) ;;
        *) printf -v "R_$role" '%s' "$value" ;;
    esac
done
unset role var value

C_RESET="${ESC}[0m"
C_DIR="${ESC}[${R_DIR}m"
C_DIM="${ESC}[${R_MUTED}m"
C_MODEL="${ESC}[${R_MODEL}m"
C_TEXT="${ESC}[${R_TEXT}m"
C_GREEN="${ESC}[${R_OK}m"
C_YELLOW="${ESC}[${R_WARN}m"
C_RED="${ESC}[${R_CRIT}m"
C_GREEN_B="${ESC}[1;${R_OK}m"
C_YELLOW_B="${ESC}[1;${R_WARN}m"
C_RED_B="${ESC}[1;${R_CRIT}m"
C_CYAN_B="${ESC}[${R_ACCENT}m"

# https://no-color.org
if [ -n "${NO_COLOR:-}" ]; then
    C_RESET="" C_DIR="" C_DIM="" C_MODEL="" C_TEXT=""
    C_GREEN="" C_YELLOW="" C_RED=""
    C_GREEN_B="" C_YELLOW_B="" C_RED_B="" C_CYAN_B=""
fi

SEP="${C_DIM} ${G_SEP} ${C_RESET}"

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

# visible_len <string> — terminal columns, without colors and link targets.
# East Asian wide characters and emoji take two columns.
visible_len() {
    strip_escapes "$1"
    local plain=$REPLY
    local width=${#plain}
    wide_count "$plain"
    REPLY=$((width + REPLY))
}

# strip_escapes <string> — the text without color codes and link targets.
# Every color code in a line is one of ours, so they are removed as literal
# strings: an extglob pattern such as $ESC\[*([0-9;])m backtracks and cost
# about 25 ms per call on a full line 2.
strip_escapes() {
    local s=$1 c pre
    case $s in
        *"$ESC"*) ;;
        *)
            REPLY=$s
            return 0
            ;;
    esac
    for c in "$C_RESET" "$C_DIR" "$C_DIM" "$C_MODEL" "$C_TEXT" "$C_GREEN" \
        "$C_YELLOW" "$C_RED" "$C_GREEN_B" "$C_YELLOW_B" "$C_RED_B" "$C_CYAN_B"; do
        [ -n "$c" ] && s=${s//"$c"/}
    done
    # OSC 8 links: ESC ] 8 ; ; URL BEL text ESC ] 8 ; ; BEL
    while :; do
        case $s in
            *"$ESC]8;;"*) ;;
            *) break ;;
        esac
        pre=${s%%"$ESC]8;;"*}
        s=${s#*"$ESC]8;;"}
        s="${pre}${s#*"$BEL"}"
    done
    REPLY=$s
}

# wide_count <string> — how many wide characters it contains.
# Works on UTF-8 bytes in the C locale, because bash 3.2 cannot be trusted
# with characters here: its printf "'c" returns the first byte, and its
# bracket ranges compare by collation, so [ -~] can match non-ASCII.
# `local LC_ALL=C` is undone on return in every bash version we support.
wide_count() {
    local LC_ALL=C
    local s=$1 g
    s=${s//[$'\001'-$'\177']/}
    REPLY=0
    [ -z "$s" ] && return 0
    # Our own glyphs and two-byte sequences (Latin, Cyrillic...) are narrow.
    for g in ━ ─ │ … ↑ ↓ ≡ −; do
        s=${s//$g/}
    done
    s=${s//[$'\302'-$'\337'][$'\200'-$'\277']/}
    local i=0 j len=${#s} b cp n count=0
    while [ "$i" -lt "$len" ]; do
        byte_at "$s" "$i"
        b=$REPLY
        if [ "$b" -ge 240 ]; then
            n=4 cp=$((b & 7))
        elif [ "$b" -ge 224 ]; then
            n=3 cp=$((b & 15))
        else
            i=$((i + 1))
            continue
        fi
        for ((j = 1; j < n; j++)); do
            byte_at "$s" $((i + j))
            cp=$(((cp << 6) | (REPLY & 63)))
        done
        [ "$cp" -ge 4352 ] && is_wide "$cp" && count=$((count + 1))
        i=$((i + n))
    done
    REPLY=$count
}

# byte_at <string> <index> — unsigned value of one byte (C locale only)
byte_at() {
    printf -v REPLY '%d' "'${1:$2:1}"
    # bash 3.2 returns a signed char.
    [ "$REPLY" -lt 0 ] && REPLY=$((REPLY + 256))
    return 0
}

# is_wide <code point> — East Asian Wide/Fullwidth blocks and emoji
is_wide() {
    local c=$1
    [ "$c" -le 4447 ] && return 0 # 1100-115F Hangul Jamo
    [ "$c" -ge 11904 ] && [ "$c" -le 42191 ] &&
        [ "$c" -ne 12351 ] && return 0                     # 2E80-A4CF CJK, kana
    [ "$c" -ge 44032 ] && [ "$c" -le 55203 ] && return 0   # AC00-D7A3 Hangul
    [ "$c" -ge 63744 ] && [ "$c" -le 64255 ] && return 0   # F900-FAFF CJK compat
    [ "$c" -ge 65072 ] && [ "$c" -le 65103 ] && return 0   # FE30-FE4F
    [ "$c" -ge 65280 ] && [ "$c" -le 65376 ] && return 0   # FF00-FF60 fullwidth
    [ "$c" -ge 65504 ] && [ "$c" -le 65510 ] && return 0   # FFE0-FFE6
    [ "$c" -ge 127744 ] && [ "$c" -le 129791 ] && return 0 # 1F300-1FAFF emoji
    [ "$c" -ge 131072 ] && [ "$c" -le 262141 ] && return 0 # 20000-3FFFD CJK ext
    return 1
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

# dir_url — file:// URL of the working directory for the line 1 link, in
# DIR_URL; empty when links are off or the path is not absolute. Computed once:
# render_location runs for every fitting level. Bytes outside the unreserved
# set are percent-encoded, so control characters cannot end the escape early.
DIR_URL=""
DIR_URL_DONE=0
dir_url() {
    [ "$DIR_URL_DONE" -eq 1 ] && return 0
    DIR_URL_DONE=1
    [ "$LINKS" -eq 1 ] || return 0
    local path=$cwd host=${HOSTNAME:-}
    case $path in /*) ;; *) return 0 ;; esac
    # The host lets a terminal tell a remote (SSH) path from a local one.
    case $host in *[!A-Za-z0-9.-]*) host="" ;; esac
    case $path in
        *[!A-Za-z0-9._~/-]*)
            local LC_ALL=C
            local i c out=""
            for ((i = 0; i < ${#path}; i++)); do
                c=${path:i:1}
                case $c in
                    [A-Za-z0-9._~/-]) out="${out}${c}" ;;
                    *)
                        byte_at "$path" "$i"
                        printf -v c '%%%02X' "$REPLY"
                        out="${out}${c}"
                        ;;
                esac
            done
            path=$out
            ;;
    esac
    DIR_URL="file://${host}${path}"
}

# short_path <path> <keep> — "…/proj/app": the last <keep> components
short_path() {
    local head=$1 tail="" i
    for ((i = 0; i < $2; i++)); do
        [ "${head%/*}" != "$head" ] || break
        tail="/${head##*/}${tail}"
        head=${head%/*}
    done
    if [ -z "$tail" ] || [ -z "$head" ] || [ "$head" = "~" ]; then
        REPLY=$1
    else
        REPLY="${G_ELLIPSIS}${tail}"
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
    local pct=$1 width=${2:-$BAR_WIDTH} filled color
    filled=$(((pct * width + 50) / 100))
    [ "$filled" -gt "$width" ] && filled=$width
    [ "$filled" -lt 0 ] && filled=0
    level_color "$pct"
    color=$REPLY
    repeat "$G_FULL" "$filled"
    local full=$REPLY
    repeat "$G_EMPTY" "$((width - filled))"
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
    local ymd day mon hhmm
    REPLY=""
    format_time "$1" '%Y%m%d %d %m %H:%M' || return 0
    read -r ymd day mon hhmm <<<"$REPLY"
    if [ -z "$TODAY" ]; then
        set_now
        format_time "$NOW" '%Y%m%d' || return 0
        TODAY=$REPLY
    fi
    if [ "$ymd" = "$TODAY" ]; then
        REPLY=$hhmm
    elif [ "$LANG_CODE" = ru ]; then
        REPLY="$((10#$day)) ${MONTHS_RU[$((10#$mon))]}, $hhmm"
    else
        REPLY="${MONTHS_EN[$((10#$mon))]} $((10#$day)), $hhmm"
    fi
}

# bash 4.2+ formats times itself with printf '%(...)T'; bash 3.2 (macOS) has
# to run date. The underscore variable forces the fallback, for the tests.
BUILTIN_TIME=0
if [ "${BASH_VERSINFO[0]}" -gt 4 ] ||
    { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }; then
    BUILTIN_TIME=1
fi
[ -n "${_STATUSLINE_FORCE_DATE:-}" ] && BUILTIN_TIME=0

# format_time <epoch> <strftime format> — local time, result in REPLY
format_time() {
    if [ "$BUILTIN_TIME" -eq 1 ]; then
        printf -v REPLY "%($2)T" "$1"
        return 0
    fi
    # GNU date takes -d @epoch, BSD/macOS date takes -r epoch.
    REPLY=$(date -d "@$1" "+$2" 2>/dev/null || date -r "$1" "+$2" 2>/dev/null)
}

# set_now — fill NOW with the current epoch, once per run, without a fork
# except on bash 3.2.
NOW="" TODAY=""
set_now() {
    [ -n "$NOW" ] && return 0
    if [ -n "${EPOCHSECONDS:-}" ]; then
        NOW=$EPOCHSECONDS
    elif [ "$BUILTIN_TIME" -eq 1 ]; then
        printf -v NOW '%(%s)T' -1
    else
        NOW=$(date +%s)
    fi
}

# --- demo -------------------------------------------------------------------

# demo_json — sample input that exercises every segment, for --demo.
# Timestamps are relative to now so the reset times stay meaningful.
demo_json() {
    set_now
    # HOME goes into a JSON string: escape what would end or break it.
    local home=${HOME:-/home/user}
    home=${home//\\/\\\\}
    home=${home//\"/\\\"}
    home=${home//$'\n'/\\n}
    home=${home//$'\t'/\\t}
    printf '%s' "{
        \"session_id\": \"demo\",
        \"session_name\": \"refactor auth middleware\",
        \"model\": {\"id\": \"claude-opus-5-5\", \"display_name\": \"Opus 5.5\"},
        \"workspace\": {
            \"current_dir\": \"${home}/projects/app\",
            \"git_worktree\": \"auth\",
            \"repo\": {\"host\": \"github.com\", \"owner\": \"example\", \"name\": \"app\"}
        },
        \"effort\": {\"level\": \"high\"},
        \"fast_mode\": true,
        \"agent\": {\"name\": \"reviewer\"},
        \"vim\": {\"mode\": \"NORMAL\"},
        \"context_window\": {
            \"used_percentage\": 62,
            \"total_input_tokens\": 620000,
            \"context_window_size\": 1000000
        },
        \"cost\": {
            \"total_cost_usd\": 3.42,
            \"total_duration_ms\": 2580000,
            \"total_lines_added\": 156,
            \"total_lines_removed\": 23
        },
        \"prompt_cache\": {
            \"caching_observed\": true, \"warm\": true,
            \"hit_ratio\": 0.91, \"expires_at\": $((NOW + 2400))
        },
        \"pr\": {
            \"number\": 42, \"review_state\": \"approved\",
            \"url\": \"https://github.com/example/app/pull/42\"
        },
        \"rate_limits\": {
            \"five_hour\": {\"used_percentage\": 34, \"resets_at\": $((NOW + 7800))},
            \"seven_day\": {\"used_percentage\": 71, \"resets_at\": $((NOW + 4 * 86400))},
            \"spend_limit\": {
                \"used_percentage\": 86, \"resets_at\": $((NOW + 12 * 86400)),
                \"used_usd\": 430, \"limit_usd\": 500
            }
        }
    }"
}

# demo_git — sample git state, so --demo never touches a real repository
demo_git() {
    git_branch="feature/auth"
    git_staged=2 git_modified=1 git_untracked=3 git_conflicted=0
    git_ahead=1 git_behind=0 git_stash=1
    shown commit || return 0
    git_subject="fix(auth): refresh expired tokens"
    if [ "$LANG_CODE" = ru ]; then git_age="2 часа назад"; else git_age="2 hours ago"; fi
}

# --- input ------------------------------------------------------------------

# Every field is optional: Claude Code omits or nulls most of them before the
# first API response. jq rounds the numbers so the rest is integer-only bash.
# read_input [json] — parse the given JSON, or stdin when none is given
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
    repo_host="" repo_owner="" repo_name=""

    local assignments program
    # shellcheck disable=SC2016  # $ctx, $rl, $spend are jq variables
    program='
        # Bash arithmetic is 64-bit, and jq prints large numbers in exponent
        # form (1e+30) that bash cannot parse: such values are dropped.
        def safe: type == "number" and . > -1e15 and . < 1e15;
        def int: if safe then round else "" end;
        def str: if type == "string" then . else "" end;
        # Free text shown as is: control characters would break the layout.
        def text: str | gsub("\\p{Cc}"; " ");
        def money:
            if type == "number" and . > 0 and . < 1e12
            then (. * 100 | round) as $cents
                | "\($cents / 100 | floor).\($cents % 100 + 100 | tostring | .[1:])"
            else "" end;
        # Whole dollars without cents ($500), the rest rounded to cents.
        def usd:
            if type == "number" and . >= 0 and . < 1e12
            then (. * 100 | round) as $cents
                | if $cents % 100 == 0 then "\($cents / 100 | floor)"
                  else "\($cents / 100 | floor).\($cents % 100 + 100 | tostring | .[1:])" end
            else "" end;
        (.context_window? // {}) as $ctx
        | (.rate_limits? // {}) as $rl
        | ($rl.spend_limit? // {}) as $spend
        | @sh "cwd=\(.workspace?.current_dir? // .cwd? | str)",
          @sh "model=\(.model?.display_name? | text)",
          @sh "effort=\(.effort?.level? | text)",
          @sh "fast=\(if .fast_mode? == true then "1" else "" end)",
          @sh "vim_mode=\(.vim?.mode? | text)",
          @sh "agent=\(.agent?.name? | text)",
          @sh "session=\(.session_name? | text)",
          @sh "session_id=\(.session_id? | str)",
          @sh "repo_host=\(.workspace?.repo?.host? | str)",
          @sh "repo_owner=\(.workspace?.repo?.owner? | str)",
          @sh "repo_name=\(.workspace?.repo?.name? | str)",
          @sh "worktree=\(.workspace?.git_worktree? // .worktree?.name? | text)",
          @sh "ctx_pct=\($ctx.used_percentage? | int)",
          @sh "ctx_used=\($ctx.total_input_tokens? | int)",
          @sh "ctx_size=\($ctx.context_window_size? | int)",
          @sh "five_pct=\($rl.five_hour?.used_percentage? | int)",
          @sh "five_reset=\($rl.five_hour?.resets_at? | int)",
          @sh "week_pct=\($rl.seven_day?.used_percentage? | int)",
          @sh "week_reset=\($rl.seven_day?.resets_at? | int)",
          @sh "spend_pct=\($spend.used_percentage? | int)",
          @sh "spend_reset=\($spend.resets_at? | int)",
          @sh "spend_usd=\(
              ($spend.used_usd? | usd) as $used | ($spend.limit_usd? | usd) as $limit
              | if $used != "" and $limit != "" then "$\($used) / $\($limit)" else "" end)",
          @sh "pr_number=\(.pr?.number? | int)",
          @sh "pr_url=\(.pr?.url? | str)",
          @sh "pr_state=\(.pr?.review_state? | str)",
          @sh "pr_kind=\(.pr?.kind? | str)",
          @sh "cost_usd=\(.cost?.total_cost_usd? | money)",
          @sh "cost_secs=\(.cost?.total_duration_ms? | if safe then . / 1000 | floor else "" end)",
          @sh "lines_added=\(.cost?.total_lines_added? | int)",
          @sh "lines_removed=\(.cost?.total_lines_removed? | int)",
          @sh "cache_state=\(
              if .prompt_cache?.caching_observed? != true then ""
              elif .prompt_cache?.warm? == true then "warm"
              else "cold" end)",
          @sh "cache_hit=\(.prompt_cache?.hit_ratio? | if safe then . * 100 | int else "" end)",
          @sh "cache_expires=\(.prompt_cache?.expires_at? | int)"
    '
    if [ $# -gt 0 ]; then
        assignments=$(printf '%s' "$1" | jq -r "$program" 2>/dev/null) || return 0
    else
        assignments=$(jq -r "$program" 2>/dev/null) || return 0
    fi
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
    # Anyone who can commit can put escape sequences in a subject.
    git_subject=${git_subject//[[:cntrl:]]/ }
    if [ "${#git_subject}" -gt "$SUBJECT_MAX" ]; then
        git_subject="${git_subject:0:$SUBJECT_MAX}${G_ELLIPSIS}"
    fi
}

# --- rendering --------------------------------------------------------------

# render_location <level> [overflow]
# Level 0 is the full line; each next level gives up something to save width:
#   1  drop the last commit
#   2  shorten the path to its last two components
#   3  shorten the path to its last component
#   4  truncate the branch name by <overflow> columns
#   5  also drop the worktree name and the pull request
#   6  also drop ahead/behind and stash
render_location() {
    local level=$1 overflow=${2:-0}
    local dir=${cwd:-?} branch=$git_branch
    dir=${dir//[[:cntrl:]]/ }
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
    if [ "$level" -ge 4 ] && [ "$overflow" -gt 0 ]; then
        local keep=$((${#branch} - overflow - 1))
        [ "$keep" -lt "$BRANCH_MIN" ] && keep=$BRANCH_MIN
        [ "$keep" -lt "${#branch}" ] && branch="${branch:0:keep}${G_ELLIPSIS}"
    fi
    dir_url
    [ -n "$DIR_URL" ] && dir="${ESC}]8;;${DIR_URL}${BEL}${dir}${ESC}]8;;${BEL}"
    local out="${C_DIR}${dir}${C_RESET}"
    if ! shown git; then
        REPLY=$out
        return
    fi
    out="${out}${SEP}"

    if [ -z "$git_branch" ]; then
        REPLY="${out}${C_DIM}${L_NO_GIT}${C_RESET}"
        return
    fi

    local color=$C_GREEN_B
    [ $((git_staged + git_modified)) -gt 0 ] && color=$C_YELLOW_B
    [ "$git_conflicted" -gt 0 ] && color=$C_RED_B
    branch_url
    link "$REPLY" "$branch"
    out="${out}${color}${REPLY}${C_RESET}"

    local tree=""
    [ "$git_conflicted" -gt 0 ] && tree="${tree} ${C_RED_B}!${git_conflicted}${C_RESET}"
    [ "$git_staged" -gt 0 ] && tree="${tree} ${C_GREEN}+${git_staged}${C_RESET}"
    [ "$git_modified" -gt 0 ] && tree="${tree} ${C_YELLOW}~${git_modified}${C_RESET}"
    [ "$git_untracked" -gt 0 ] && tree="${tree} ${C_DIM}?${git_untracked}${C_RESET}"
    out="${out}${tree:- ${C_DIM}${L_CLEAN}${C_RESET}}"

    if [ "$level" -lt 6 ]; then
        [ "$git_ahead" -gt 0 ] && out="${out} ${C_CYAN_B}${G_AHEAD}${git_ahead}${C_RESET}"
        [ "$git_behind" -gt 0 ] && out="${out} ${C_RED_B}${G_BEHIND}${git_behind}${C_RESET}"
        [ "$git_stash" -gt 0 ] && out="${out} ${C_DIM}${G_STASH}${git_stash}${C_RESET}"
    fi
    [ -n "$worktree" ] && shown worktree && [ "$level" -lt 5 ] &&
        out="${out} ${C_DIM}wt:${worktree}${C_RESET}"
    if [ -n "$pr_number" ] && shown pr && [ "$level" -lt 5 ]; then
        render_pr
        out="${out} ${REPLY}"
    fi
    [ -n "$git_subject" ] && [ "$level" -lt 1 ] &&
        out="${out}${SEP}${C_DIM}${git_subject} ${G_DOT} ${git_age}${C_RESET}"
    REPLY=$out
}

# branch_url — where the branch name links to: the branch on GitHub, the
# repository root on other hosts (their branch URLs differ), nothing when
# Claude Code reports no origin remote. Anything that would need URL-encoding
# is left out rather than encoded.
branch_url() {
    REPLY=""
    case "${repo_host}/${repo_owner}/${repo_name}" in
        /* | */ | *//* | *[!A-Za-z0-9._/-]*) return 0 ;;
    esac
    REPLY="https://${repo_host}/${repo_owner}/${repo_name}"
    [ "$repo_host" = github.com ] || return 0
    case $git_branch in
        *[!A-Za-z0-9._/-]*) ;;
        *) REPLY="${REPLY}/tree/${git_branch}" ;;
    esac
}

# render_pr — "#123 approved", colored by review state and linked to the PR.
# GitLab merge requests are written "!123".
render_pr() {
    local color=$C_CYAN_B label="#${pr_number}"
    [ "$pr_kind" = mr ] && label="!${pr_number}"
    case $pr_state in
        approved) color=$C_GREEN && label="${label} ${L_APPROVED}" ;;
        changes_requested) color=$C_RED && label="${label} ${L_CHANGES}" ;;
        pending) color=$C_YELLOW && label="${label} ${L_PENDING}" ;;
        draft) color=$C_DIM && label="${label} ${L_DRAFT}" ;;
    esac
    link "$pr_url" "$label"
    REPLY="${color}${REPLY}${C_RESET}"
}

# fit_location — the fullest line 1 that fits MAX_WIDTH
fit_location() {
    local level line overflow
    for level in 0 1 2 3 4 5 6; do
        render_location "$level"
        [ "$MAX_WIDTH" -eq 0 ] && return
        line=$REPLY
        visible_len "$line"
        overflow=$((REPLY - MAX_WIDTH))
        # The branch is cut by this level's own overflow, measured with the
        # full branch: an overflow left over from the level before would cut
        # it by too little once the worktree and the PR are gone.
        if [ "$overflow" -gt 0 ] && [ "$level" -ge 4 ]; then
            render_location "$level" "$overflow"
            line=$REPLY
            visible_len "$line"
            overflow=$((REPLY - MAX_WIDTH))
        fi
        [ "$overflow" -le 0 ] && break
    done
    REPLY=$line
}

# join_fit [use head forms] — join SEGMENTS with the separator, dropping
# segments from the end until the line fits MAX_WIDTH. The first segment
# always stays; on line 2 it may still shrink through HEAD_FORMS.
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
    # Down to the first segment and still too wide: try its shorter forms.
    if [ "${1:-0}" -eq 1 ] && [ "$MAX_WIDTH" -gt 0 ] && [ "$count" -le 1 ]; then
        for line in "${HEAD_FORMS[@]}"; do
            visible_len "$line"
            [ "$REPLY" -le "$MAX_WIDTH" ] && break
        done
    fi
    REPLY=$line
}

# head_form <with effort> <with fast> <with agent> — the model segment
head_form() {
    local out="${C_MODEL}${model:-?}"
    if [ -n "$ctx_size" ]; then
        fmt_tokens "$ctx_size"
        out="${out} (${REPLY})"
    fi
    [ "$1" -eq 1 ] && [ -n "$effort" ] && shown effort && out="${out} (${effort})"
    out="${out}${C_RESET}"
    [ "$2" -eq 1 ] && [ -n "$fast" ] && shown fast && out="${out} ${C_YELLOW_B}${L_FAST}${C_RESET}"
    [ "$3" -eq 1 ] && [ -n "$agent" ] && shown agent && out="${out} ${C_CYAN_B}@${agent}${C_RESET}"
    REPLY=$out
}

# render_heads — HEAD_FORMS: the model segment, then shorter forms of it. It
# always stays; on a very narrow terminal it sheds the agent, then fast mode,
# then effort.
render_heads() {
    HEAD_FORMS=()
    head_form 1 1 1 && HEAD_FORMS+=("$REPLY")
    head_form 1 1 0 && HEAD_FORMS+=("$REPLY")
    head_form 1 0 0 && HEAD_FORMS+=("$REPLY")
    head_form 0 0 0 && HEAD_FORMS+=("$REPLY")
}

# render_segment <name> — one line-2 segment in REPLY, empty when it has no
# data or is hidden
render_segment() {
    local out
    REPLY=""
    case $1 in
        context)
            [ -n "$ctx_pct" ] && shown context || return 0
            bar "$ctx_pct"
            out="${C_DIM}${L_CTX}${C_RESET} ${REPLY} ${C_TEXT}${ctx_pct}%"
            if [ -n "$ctx_used" ] && [ -n "$ctx_size" ] && shown tokens; then
                fmt_tokens "$ctx_used"
                out="${out} (${REPLY} / "
                fmt_tokens "$ctx_size"
                out="${out}${REPLY})"
            fi
            REPLY="${out}${C_RESET}"
            ;;
        cost)
            shown cost && render_cost
            ;;
        cache)
            [ -n "$cache_state" ] && shown cache && render_cache
            ;;
        vim)
            [ -n "$vim_mode" ] && shown vim || return 0
            local color=$C_GREEN_B
            [ "$vim_mode" = NORMAL ] && color=$C_YELLOW_B
            REPLY="${color}${vim_mode}${C_RESET}"
            ;;
        session)
            [ -n "$session" ] && shown session || return 0
            local name=$session
            [ "${#name}" -gt "$SESSION_MAX" ] && name="${name:0:SESSION_MAX}${G_ELLIPSIS}"
            REPLY="${C_DIM}${name}${C_RESET}"
            ;;
    esac
    return 0
}

# render_lines — print line 2 and any extra layout lines
render_lines() {
    local g name
    render_heads
    for ((g = 0; g < ${#LAYOUT_GROUPS[@]}; g++)); do
        if [ "$g" -eq 0 ]; then
            SEGMENTS=("${HEAD_FORMS[0]}")
        else
            SEGMENTS=()
        fi
        for name in ${LAYOUT_GROUPS[g]}; do
            render_segment "$name"
            [ -n "$REPLY" ] && SEGMENTS+=("$REPLY")
        done
        [ "${#SEGMENTS[@]}" -gt 0 ] || continue
        join_fit $((g == 0 ? 1 : 0))
        printf '%s\n' "$REPLY"
    done
}

# compact_limit <label> <percent> — append "5h 34%" to SEGMENTS
compact_limit() {
    [ -n "$2" ] || return 0
    level_color "$2"
    SEGMENTS+=("${C_DIM}$1${C_RESET} ${REPLY}$2%${C_RESET}")
}

# render_compact — everything essential on one line: the shortest form of
# the location (last path component, branch and working tree state) │ model
# and effort │ context % │ limit percentages. Segments drop from the end.
render_compact() {
    render_location 6
    SEGMENTS=("$REPLY")
    head_form 1 0 0
    SEGMENTS+=("$REPLY")
    if [ -n "$ctx_pct" ] && shown context; then
        level_color "$ctx_pct"
        SEGMENTS+=("${C_DIM}${L_CTX}${C_RESET} ${REPLY}${ctx_pct}%${C_RESET}")
    fi
    if shown limits; then
        if shown current; then compact_limit "$L_5H" "$five_pct"; fi
        if shown weekly; then compact_limit "$L_7D" "$week_pct"; fi
        if shown spend; then compact_limit "$L_SPEND" "$spend_pct"; fi
    fi
    join_fit 0
}

# render_cache — "Cache 91% · 19:30" while the prompt cache is warm (hit ratio
# and when it goes cold), "Cache cold" once it has expired
render_cache() {
    if [ "$cache_state" = cold ]; then
        REPLY="${C_DIM}${L_CACHE}${C_RESET} ${C_YELLOW}${L_COLD}${C_RESET}"
        return
    fi
    local out="${C_DIM}${L_CACHE}${C_RESET}"
    [ -n "$cache_hit" ] && out="${out} ${C_GREEN}${cache_hit}%${C_RESET}"
    if [ -n "$cache_expires" ]; then
        fmt_reset "$cache_expires"
        if [ -n "$REPLY" ]; then
            [ -n "$cache_hit" ] && out="${out}${C_DIM} ${G_DOT}${C_RESET}"
            out="${out} ${C_DIM}${REPLY}${C_RESET}"
        fi
    fi
    [ -z "${cache_hit}${cache_expires}" ] && out="${out} ${C_GREEN}${L_WARM}${C_RESET}"
    REPLY=$out
}

# render_cost — "$1.24 · 38m · +156 −23"; empty when there is nothing to show
render_cost() {
    local out="" dot="${C_DIM} ${G_DOT} ${C_RESET}"
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
        out="${out:+${out}${dot}}${C_GREEN}+${lines_added:-0}${C_RESET} ${C_RED}${G_MINUS}${lines_removed:-0}${C_RESET}"
    fi
    REPLY=$out
}

# render_limit <level> <label> <percent> <reset epoch> [note] [bar width]
# Level 0 is the full row; level 1 drops the note, level 2 the reset time.
render_limit() {
    local level=$1 label=$2 pct=$3 reset=$4 note=${5:-} width=${6:-$BAR_WIDTH} out pad
    # Padded by hand: printf counts bytes, and the labels can be Cyrillic.
    printf -v pad '%*s' $((LIMIT_LABEL_WIDTH - ${#label})) ''
    bar "$pct" "$width"
    out="${C_DIM}${label}${pad}${C_RESET}${REPLY} ${C_DIM}${pct}%${C_RESET}"
    if [ -n "$reset" ] && [ "$level" -lt 2 ]; then
        fmt_reset "$reset"
        [ -n "$REPLY" ] && out="${out}  ${C_DIM}${REPLY}${C_RESET}"
    fi
    [ -n "$note" ] && [ "$level" -lt 1 ] && out="${out}  ${C_DIM}${note}${C_RESET}"
    REPLY=$out
}

# fit_limit <label> <percent> <reset epoch> [note] — the fullest limit row
# that fits MAX_WIDTH: drop the note, then the reset time, then shorten the
# bar down to 5 cells.
fit_limit() {
    local level line width
    for level in 0 1 2; do
        render_limit "$level" "$@"
        [ "$MAX_WIDTH" -eq 0 ] && return
        line=$REPLY
        visible_len "$line"
        if [ "$REPLY" -le "$MAX_WIDTH" ]; then
            REPLY=$line
            return
        fi
    done
    width=$((BAR_WIDTH - (REPLY - MAX_WIDTH)))
    [ "$width" -lt 5 ] && width=5
    render_limit 2 "$1" "$2" "$3" "${4:-}" "$width"
}

# --- main -------------------------------------------------------------------

main() {
    local demo=0
    case ${1:-} in
        -v | --version)
            echo "claude-statusline $VERSION"
            return 0
            ;;
        --demo) demo=1 ;;
    esac

    if ! command -v jq >/dev/null 2>&1; then
        if [ "$LANG_CODE" = ru ]; then
            echo "claude-statusline: jq не найден"
        else
            echo "claude-statusline: jq not found"
        fi
        return 0
    fi

    if [ "$demo" -eq 1 ]; then
        read_input "$(demo_json)"
        reset_git
        shown git && demo_git
    else
        read_input
        read_git
    fi

    if [ "$COMPACT" -eq 1 ]; then
        render_compact
        printf '%s\n' "$REPLY"
        return 0
    fi

    fit_location
    printf '%s\n' "$REPLY"
    render_lines
    shown limits || return 0
    if [ -n "$five_pct" ] && shown current; then
        fit_limit "$L_CURRENT" "$five_pct" "$five_reset"
        printf '%s\n' "$REPLY"
    fi
    if [ -n "$week_pct" ] && shown weekly; then
        fit_limit "$L_WEEKLY" "$week_pct" "$week_reset"
        printf '%s\n' "$REPLY"
    fi
    # Present only behind a Claude apps gateway with a spend limit.
    if [ -n "$spend_pct" ] && shown spend; then
        fit_limit "$L_SPEND" "$spend_pct" "$spend_reset" "$spend_usd"
        printf '%s\n' "$REPLY"
    fi
}

main "$@"
