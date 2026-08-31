#!/usr/bin/env bash
# Claude Code status line script
# Shows: directory  branch  model (ctx size)  context bar

# Use C locale for numeric formatting (bc emits "." which printf rejects under ru_RU etc.)
export LC_NUMERIC=C

input=$(cat)

cwd=$(echo "$input"     | jq -r '.cwd // .workspace.current_dir // "?"')
model=$(echo "$input"   | jq -r '.model.display_name // "?"')
model_id=$(echo "$input" | jq -r '.model.id // ""')
used_pct=$(echo "$input"      | jq -r '.context_window.used_percentage // empty')
used_tokens=$(echo "$input"   | jq -r '.context_window.total_input_tokens // empty')
ctx_window=$(echo "$input"    | jq -r '.context_window.context_window_size // empty')
effort=$(echo "$input"        | jq -r '.effort.level // empty')

# Rate limit usage (5-hour rolling window + 7-day window)
five_pct=$(echo "$input"    | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_reset=$(echo "$input"  | jq -r '.rate_limits.five_hour.resets_at // empty')
seven_pct=$(echo "$input"   | jq -r '.rate_limits.seven_day.used_percentage // empty')
seven_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
sonnet_pct=$(echo "$input"   | jq -r '.rate_limits.seven_day_sonnet.used_percentage // empty')
sonnet_reset=$(echo "$input" | jq -r '.rate_limits.seven_day_sonnet.resets_at // empty')

# Shorten home directory to ~
home="$HOME"
short_cwd="${cwd/#$home/\~}"

# Git info
git_branch="" git_staged=0 git_modified=0 git_untracked=0 git_conflicted=0 git_ahead=0 git_behind=0 git_stash=0
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
    git_branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null \
        || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
    git_st=$(git -C "$cwd" status --porcelain=v1 2>/dev/null)
    git_staged=$(printf '%s\n' "$git_st"    | grep -c '^[MADRCT]' 2>/dev/null); git_staged=${git_staged:-0}
    git_modified=$(printf '%s\n' "$git_st"  | grep -c '^.[MD]'    2>/dev/null); git_modified=${git_modified:-0}
    git_untracked=$(printf '%s\n' "$git_st" | grep -c '^??'       2>/dev/null); git_untracked=${git_untracked:-0}
    git_conflicted=$(printf '%s\n' "$git_st"| grep -c '^[UA][UA]\|^DD\|^AA' 2>/dev/null); git_conflicted=${git_conflicted:-0}
    ab=$(git -C "$cwd" rev-list --count --left-right "@{upstream}...HEAD" 2>/dev/null)
    [ -n "$ab" ] && git_behind=$(echo "$ab" | cut -f1) && git_ahead=$(echo "$ab" | cut -f2)
    git_stash=$(git -C "$cwd" stash list 2>/dev/null | wc -l)
    git_last_commit=$(git -C "$cwd" log -1 --format="%s" 2>/dev/null | cut -c1-40)
    git_last_commit_time=$(git -C "$cwd" log -1 --format="%cr" 2>/dev/null)
fi

# Context window size label — derived from the model's real context window
ctx_size="200K"
if [ -n "$ctx_window" ]; then
    cw_int=${ctx_window%%.*}
    if [ "$cw_int" -ge 1000000 ] 2>/dev/null; then
        whole=$(( cw_int / 1000000 ))
        frac=$(( (cw_int % 1000000) / 100000 ))   # first decimal of the millions value
        if [ "$frac" -eq 0 ]; then ctx_size="${whole}M"; else ctx_size="${whole}.${frac}M"; fi
    elif [ "$cw_int" -ge 1000 ] 2>/dev/null; then
        ctx_size="$(( cw_int / 1000 ))K"
    fi
fi

# Context fill bar (20 block segments using unicode block chars)
bar_str=""
if [ -n "$used_pct" ]; then
    filled=$(printf "%.0f" "$(echo "$used_pct * 20 / 100" | bc -l 2>/dev/null || echo 0)")
    filled=$(( filled > 20 ? 20 : filled ))
    empty=$(( 20 - filled ))
    blocks_filled=""
    blocks_empty=""
    for i in $(seq 1 "$filled"); do blocks_filled="${blocks_filled}\xe2\x94\x81"; done   # ━ U+2501 HEAVY HORIZONTAL
    for i in $(seq 1 "$empty");  do blocks_empty="${blocks_empty}\xe2\x94\x80"; done     # ─ U+2500 LIGHT HORIZONTAL
    bar_str="filled:${blocks_filled}:empty:${blocks_empty}:pct:$(printf '%.0f' "$used_pct")"
fi

# ANSI color codes
C_RESET="\e[0m"
C_BOLD="\e[1m"
C_DIM="\e[2m"
C_CYAN="\e[1;36m"       # bold cyan — directory
C_GRAY="\e[2;37m"       # dim gray — separator
C_GREEN="\e[1;32m"      # bold green — git branch
C_MAGENTA="\e[1;35m"    # bold magenta — model name
C_BAR_EMPTY="\e[2;37m"  # dim gray — empty bar blocks
C_BAR_PCT="\e[37m"      # white — percentage

# Unicode separator
SEP="${C_GRAY} \xe2\x94\x82 ${C_RESET}"   # │
C_LABEL="\e[2;37m"         # dim gray — usage row labels

# Format a reset timestamp in Russian, 24h: time-only if today, else "10 мар, 19:30"
fmt_reset() {
    local ts="$1"
    [ -z "$ts" ] && return
    local ru_months=("" "янв" "фев" "мар" "апр" "май" "июн" "июл" "авг" "сен" "окт" "ноя" "дек")
    local mon day hhmm
    mon=$(date -d "@$ts" "+%-m" 2>/dev/null)
    day=$(date -d "@$ts" "+%-d" 2>/dev/null)
    hhmm=$(date -d "@$ts" "+%H:%M" 2>/dev/null)
    if [ "$(date +%Y%m%d)" = "$(date -d "@$ts" +%Y%m%d 2>/dev/null)" ]; then
        printf "%s" "$hhmm"
    else
        printf "%s %s, %s" "$day" "${ru_months[$mon]}" "$hhmm"
    fi
}

# Render one usage row: label, block bar with dynamic color, percentage, reset time
render_usage_line() {
    local label="$1" pct="$2" reset_ts="$3"
    local filled empty i fb="" eb="" reset_str fill_color empty_color pct_color
    filled=$(printf "%.0f" "$(echo "$pct * 20 / 100" | bc -l 2>/dev/null || echo 0)")
    [ "$filled" -gt 20 ] 2>/dev/null && filled=20
    [ "$filled" -lt 0 ]  2>/dev/null && filled=0
    empty=$(( 20 - filled ))
    # Color by usage level: green < 50%, yellow < 80%, red >= 80%
    local pct_int=${pct%%.*}
    if [ "${pct_int:-0}" -ge 80 ] 2>/dev/null; then
        fill_color="\e[31m"
    elif [ "${pct_int:-0}" -ge 50 ] 2>/dev/null; then
        fill_color="\e[33m"
    else
        fill_color="\e[32m"
    fi
    local empty_color="\e[2;37m" pct_color="\e[2;37m"
    for ((i=0; i<filled; i++)); do fb="${fb}\xe2\x94\x81"; done   # ━ U+2501 HEAVY HORIZONTAL
    for ((i=0; i<empty;  i++)); do eb="${eb}\xe2\x94\x80"; done   # ─ U+2500 LIGHT HORIZONTAL
    reset_str=$(fmt_reset "$reset_ts")
    local pct_disp
    pct_disp=$(printf "%.0f" "$pct" 2>/dev/null || echo "$pct")
    printf "${C_LABEL}%-8s${C_RESET}${fill_color}${fb}${empty_color}${eb}${C_RESET} ${pct_color}%s%%${C_RESET}  ${C_GRAY}%s${C_RESET}" \
        "$label" "$pct_disp" "$reset_str"
}

# Line 1: directory + git block
line1="$(printf "${C_CYAN}")${short_cwd}$(printf "${C_RESET}")"
if [ -n "$git_branch" ]; then
    # Branch color: red if conflicts, yellow if dirty, green if clean
    b_color="$C_GREEN"
    if [ "$git_staged" -gt 0 ] || [ "$git_modified" -gt 0 ]; then b_color="\e[1;33m"; fi
    if [ "$git_conflicted" -gt 0 ]; then b_color="\e[1;31m"; fi
    git_block="$(printf "${b_color}")${git_branch}$(printf "${C_RESET}")"
    # Working tree status — show [clean] stub when nothing changed
    git_dirty=""
    [ "$git_conflicted" -gt 0 ] && git_dirty="${git_dirty} $(printf '\e[1;31m')!${git_conflicted}$(printf "${C_RESET}")"
    [ "$git_staged"     -gt 0 ] && git_dirty="${git_dirty} $(printf '\e[32m')+${git_staged}$(printf "${C_RESET}")"
    [ "$git_modified"   -gt 0 ] && git_dirty="${git_dirty} $(printf '\e[33m')~${git_modified}$(printf "${C_RESET}")"
    [ "$git_untracked"  -gt 0 ] && git_dirty="${git_dirty} $(printf "${C_GRAY}")?${git_untracked}$(printf "${C_RESET}")"
    if [ -n "$git_dirty" ]; then
        git_block="${git_block}${git_dirty}"
    else
        git_block="${git_block} $(printf "${C_GRAY}")[clean]$(printf "${C_RESET}")"
    fi
    # Ahead/behind remote
    [ "$git_ahead"  -gt 0 ] && git_block="${git_block} $(printf '\e[1;36m')↑${git_ahead}$(printf "${C_RESET}")"
    [ "$git_behind" -gt 0 ] && git_block="${git_block} $(printf '\e[1;31m')↓${git_behind}$(printf "${C_RESET}")"
    # Stash
    [ "$git_stash"  -gt 0 ] && git_block="${git_block} $(printf "${C_GRAY}")≡${git_stash}$(printf "${C_RESET}")"
    [ -n "$git_last_commit" ] && git_block="${git_block}$(printf "${SEP}")$(printf "${C_GRAY}")${git_last_commit} · ${git_last_commit_time}$(printf "${C_RESET}")"
    line1="${line1}$(printf "${SEP}")${git_block}"
else
    line1="${line1}$(printf "${SEP}")$(printf "${C_GRAY}")[no git]$(printf "${C_RESET}")"
fi

# Line 2: model + context bar
effort_label=""
[ -n "$effort" ] && effort_label=" $(printf "${C_MAGENTA}")(${effort})$(printf "${C_RESET}")"
line2="$(printf "${C_MAGENTA}")${model} (${ctx_size})$(printf "${C_RESET}")${effort_label}"
if [ -n "$bar_str" ]; then
    filled_blocks=$(echo "$bar_str" | sed 's/filled:\(.*\):empty:.*/\1/')
    empty_blocks=$(echo "$bar_str"  | sed 's/.*:empty:\(.*\):pct:.*/\1/')
    pct_val=$(echo "$bar_str"       | sed 's/.*:pct:\(.*\)/\1/')
    ctx_pct_int=${used_pct%%.*}
    ctx_fill_color="\e[32m"
    [ "${ctx_pct_int:-0}" -ge 80 ] 2>/dev/null && ctx_fill_color="\e[31m"
    [ "${ctx_pct_int:-0}" -ge 50 ] 2>/dev/null && [ "${ctx_pct_int:-0}" -lt 80 ] 2>/dev/null && ctx_fill_color="\e[33m"
    colored_bar="$(printf "${ctx_fill_color}${filled_blocks}${C_BAR_EMPTY}${empty_blocks}${C_RESET}")"
    token_counts=""
    if [ -n "$used_tokens" ] && [ -n "$ctx_window" ]; then
        used_k=$(printf "%.0f" "$(echo "$used_tokens / 1000" | bc -l 2>/dev/null || echo 0)")
        total_k=$(printf "%.0f" "$(echo "$ctx_window / 1000" | bc -l 2>/dev/null || echo 0)")
        token_counts=" (${used_k}K / ${total_k}K)"
    fi
    line2="${line2}$(printf "${SEP}")$(printf "${C_GRAY}")Ctx$(printf "${C_RESET}") ${colored_bar}$(printf " ${C_BAR_PCT}${pct_val}%%${token_counts}${C_RESET}")"
fi

# Lines 3–4: rate limit rows
line3=""
[ -n "$five_pct" ]   && line3="$(render_usage_line "Current" "$five_pct"   "$five_reset")"
[ -n "$seven_pct" ]  && line3="${line3}\n$(render_usage_line "Weekly"  "$seven_pct"  "$seven_reset")"
[ -n "$sonnet_pct" ] && line3="${line3}\n$(render_usage_line "Sonnet"  "$sonnet_pct" "$sonnet_reset")"

out="${line1}\n${line2}"
[ -n "$line3" ] && out="${out}\n${line3}"

printf "%b" "$out"
