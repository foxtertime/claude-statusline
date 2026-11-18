#!/usr/bin/env bash
# Тесты claude-statusline. Без зависимостей, кроме bash, jq и git.
# Запуск: make test  (или ./tests/run.sh)
#
# Скрипты запускаются тем же bash, что и тесты, поэтому
# `/bin/bash tests/run.sh` на macOS проверяет совместимость с bash 3.2.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/statusline.sh"
INSTALLER="$ROOT/install.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Изолируемся от настроек git и локали разработчика.
export HOME="$TMP/home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export TZ=UTC NO_COLOR=1
unset CLAUDE_CONFIG_DIR COLUMNS
unset STATUSLINE_LANG STATUSLINE_BAR_WIDTH STATUSLINE_WARN STATUSLINE_CRIT STATUSLINE_HIDE
unset STATUSLINE_RESET STATUSLINE_GIT_CACHE
export XDG_CACHE_HOME="$TMP/cache"
mkdir -p "$HOME"

passed=0 failed=0 current=""

t() { current=$1; }

ok() { passed=$((passed + 1)); }

fail() {
    failed=$((failed + 1))
    printf 'FAIL  %s\n      %s\n' "$current" "$1"
    [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/      | /'
}

contains() {
    case $1 in
        *"$2"*) ok ;;
        *) fail "нет подстроки: $2" "$1" ;;
    esac
}

lacks() {
    case $1 in
        *"$2"*) fail "лишняя подстрока: $2" "$1" ;;
        *) ok ;;
    esac
}

equals() {
    if [ "$1" = "$2" ]; then ok; else fail "ожидалось: $2" "$1"; fi
}

# render <json> — вывод статуслайна для данного JSON
render() { printf '%s' "$1" | "$BASH" "$SCRIPT"; }

# line <n> <text>
line() { printf '%s\n' "$2" | sed -n "${1}p"; }

# new_repo <name> — репозиторий с одним коммитом, путь в REPO
new_repo() {
    REPO="$TMP/$1"
    git init -q -b main "$REPO"
    echo one >"$REPO/file"
    git -C "$REPO" add file
    git -C "$REPO" commit -q -m "${2:-initial}"
}

in_dir() { printf '{"workspace":{"current_dir":"%s"}}' "$1"; }

# --- версия -----------------------------------------------------------------

t "--version совпадает с VERSION и CHANGELOG"
version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$SCRIPT")
equals "$("$BASH" "$SCRIPT" --version)" "claude-statusline $version"
equals "$("$BASH" "$SCRIPT" -v)" "claude-statusline $version"
released=$(sed -n 's/^## \[\([0-9][^]]*\)\].*/\1/p' "$ROOT/CHANGELOG.md" | head -1)
equals "$released" "$version"

# --- устойчивость к входу ---------------------------------------------------

t "пустой объект"
out=$(render '{}')
equals "$?" "0"
equals "$out" "? │ [no git]
?"

t "невалидный JSON и пустой stdin не роняют скрипт"
out=$(render 'not json')
equals "$?" "0"
contains "$out" "[no git]"
out=$(render '')
equals "$?" "0"

t "null-поля в начале сессии"
out=$(render '{"model":{"display_name":"Opus"},"context_window":{"used_percentage":null,"context_window_size":200000,"current_usage":null}}')
equals "$(line 2 "$out")" "Opus (200K)"

t "устаревший cwd используется, если нет workspace.current_dir"
out=$(render '{"cwd":"/legacy"}')
contains "$out" "/legacy │"
out=$(render '{"cwd":"/legacy","workspace":{"current_dir":"/current"}}')
contains "$out" "/current │"

# --- директория -------------------------------------------------------------

t "домашний каталог сокращается до ~"
tilde='~' # буквальная тильда: в выводе она не раскрывается
contains "$(render "$(in_dir "$HOME")")" "$tilde │"
contains "$(render "$(in_dir "$HOME/work")")" "$tilde/work │"
contains "$(render "$(in_dir "${HOME}2/work")")" "${HOME}2/work │"

# --- модель и контекст ------------------------------------------------------

t "модель, размер контекста, effort"
out=$(render '{"model":{"display_name":"Opus 5"},"effort":{"level":"high"},"context_window":{"context_window_size":1000000}}')
equals "$(line 2 "$out")" "Opus 5 (1M) (high)"

t "шкала контекста и токены"
out=$(render '{"model":{"display_name":"M"},"context_window":{"used_percentage":12.4,"total_input_tokens":125400,"context_window_size":1000000}}')
equals "$(line 2 "$out")" "M (1M) │ Ctx ━━────────────────── 12% (125K / 1M)"
out=$(render '{"context_window":{"used_percentage":100,"total_input_tokens":950,"context_window_size":1500000}}')
contains "$out" "━━━━━━━━━━━━━━━━━━━━ 100% (950 / 1.5M)"
out=$(render '{"context_window":{"used_percentage":0}}')
contains "$out" "Ctx ──────────────────── 0%"

t "цвет шкалы зависит от уровня"
esc=$'\033'
colored() { printf '{"context_window":{"used_percentage":%s}}' "$1" | NO_COLOR='' "$BASH" "$SCRIPT"; }
contains "$(colored 49)" "${esc}[32m━"
contains "$(colored 50)" "${esc}[33m━"
contains "$(colored 80)" "${esc}[31m━"

t "NO_COLOR отключает escape-последовательности"
lacks "$(render '{"context_window":{"used_percentage":50},"rate_limits":{"five_hour":{"used_percentage":1}}}')" "$esc"

# --- лимиты -----------------------------------------------------------------

t "лимиты: нет rate_limits — нет строк"
equals "$(render '{}' | wc -l | tr -d ' ')" "2"

# Время «сейчас» фиксируется один раз, а его запись ЧЧ:ММ считается из той же
# метки (TZ=UTC), иначе тест падал бы на границе минуты.
now=$(date +%s)
now_hhmm=$(printf '%02d:%02d' $((now % 86400 / 3600)) $((now % 3600 / 60)))
t "лимиты: время сброса сегодня и в другой день"
out=$(render "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":$now},\"seven_day\":{\"used_percentage\":81.2,\"resets_at\":1741635000}}}")
equals "$(line 3 "$out")" "Current ━━━━━─────────────── 24%  $now_hhmm"
equals "$(line 4 "$out")" "Weekly  ━━━━━━━━━━━━━━━━──── 81%  10 мар, 19:30"

t "лимиты: окна независимы, resets_at необязателен"
out=$(render '{"rate_limits":{"seven_day":{"used_percentage":5}}}')
equals "$(line 3 "$out")" "Weekly  ━─────────────────── 5%"
lacks "$out" "Current"

t "лимиты: spend_limit с суммами и без, выше 100%"
out=$(render '{"rate_limits":{"spend_limit":{"used_percentage":62.8,"resets_at":1741635000,"used_usd":314.12,"limit_usd":500}}}')
equals "$(line 3 "$out")" "Spend   ━━━━━━━━━━━━━─────── 63%  10 мар, 19:30  \$314.12 / \$500"
out=$(render '{"rate_limits":{"spend_limit":{"used_percentage":130}}}')
equals "$(line 3 "$out")" "Spend   ━━━━━━━━━━━━━━━━━━━━ 130%"

t "лимиты: STATUSLINE_RESET=relative — время до сброса"
# Запас в 30 секунд, чтобы результат не зависел от момента запуска.
resets_in() { printf '{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":%s}}}' "$(($(date +%s) + $1))"; }
relative() { line 3 "$(STATUSLINE_RESET=relative render "$(resets_in "$1")")"; }
equals "$(relative 7830)" "Current ━─────────────────── 5%  через 2 ч 10 мин"
equals "$(relative 273630)" "Current ━─────────────────── 5%  через 3 д 4 ч"
equals "$(relative 330)" "Current ━─────────────────── 5%  через 5 мин"
equals "$(relative 20)" "Current ━─────────────────── 5%  через <1 мин"
equals "$(relative -500)" "Current ━─────────────────── 5%  через <1 мин"
equals "$(STATUSLINE_LANG=en relative 7830)" "Current ━─────────────────── 5%  in 2h 10m"
equals "$(STATUSLINE_LANG=en relative 20)" "Current ━─────────────────── 5%  in <1m"
equals "$(line 3 "$(STATUSLINE_RESET=bogus render "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":5,\"resets_at\":$now}}}")")" "Current ━─────────────────── 5%  $now_hhmm"

t "лимиты: seven_day_sonnet больше не выводится"
lacks "$(render '{"rate_limits":{"seven_day_sonnet":{"used_percentage":8}}}')" "Sonnet"

# --- настройки --------------------------------------------------------------

full='{"model":{"display_name":"M"},"effort":{"level":"high"},"context_window":{"used_percentage":50,"total_input_tokens":100000,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":20,"resets_at":1741635000},"spend_limit":{"used_percentage":30}}}'

t "настройки: STATUSLINE_LANG"
contains "$(STATUSLINE_LANG=en render "$full")" "20%  Mar 10, 19:30"
contains "$(STATUSLINE_LANG=ru render "$full")" "20%  10 мар, 19:30"
contains "$(STATUSLINE_LANG=xx render "$full")" "20%  10 мар, 19:30"

t "настройки: STATUSLINE_BAR_WIDTH"
equals "$(line 2 "$(STATUSLINE_BAR_WIDTH=10 render "$full")")" "M (200K) (high) │ Ctx ━━━━━───── 50% (100K / 200K)"
for bad in 4 61 abc -5 99999; do
    contains "$(STATUSLINE_BAR_WIDTH=$bad render "$full")" "Ctx ━━━━━━━━━━────────── 50%"
done

t "настройки: STATUSLINE_WARN и STATUSLINE_CRIT"
ctx50() { printf '{"context_window":{"used_percentage":50}}' | NO_COLOR='' "$@" "$BASH" "$SCRIPT"; }
contains "$(ctx50 env STATUSLINE_WARN=60)" "${esc}[32m━"
contains "$(ctx50 env STATUSLINE_CRIT=50)" "${esc}[31m━"
contains "$(ctx50 env STATUSLINE_WARN=90 STATUSLINE_CRIT=10)" "${esc}[33m━"
contains "$(ctx50 env STATUSLINE_WARN=abc STATUSLINE_CRIT=x)" "${esc}[33m━"

t "настройки: STATUSLINE_HIDE"
equals "$(line 2 "$(STATUSLINE_HIDE=effort,tokens render "$full")")" "M (200K) │ Ctx ━━━━━━━━━━────────── 50%"
equals "$(line 2 "$(STATUSLINE_HIDE=context render "$full")")" "M (200K) (high)"
equals "$(STATUSLINE_HIDE=limits render "$full" | wc -l | tr -d ' ')" "2"
out=$(STATUSLINE_HIDE="current, spend" render "$full")
contains "$out" "Weekly"
lacks "$out" "Current"
lacks "$out" "Spend"
equals "$(line 1 "$(STATUSLINE_HIDE=git render '{"cwd":"/x"}')")" "/x"

# --- git --------------------------------------------------------------------

t "настройки: STATUSLINE_HIDE=commit"
new_repo nocommit
equals "$(line 1 "$(STATUSLINE_HIDE=commit render "$(in_dir "$REPO")")")" "$REPO │ main [clean]"

# --- ширина терминала -------------------------------------------------------

t "ширина: строка 1 упрощается по шагам"
mkdir -p "$HOME/work/proj"
git init -q -b main "$HOME/work/proj/app"
git -C "$HOME/work/proj/app" commit -q --allow-empty -m initial
app=$(in_dir "$HOME/work/proj/app")
width() { line 1 "$(COLUMNS=$1 render "$app")"; }
contains "$(line 1 "$(render "$app")")" "$tilde/work/proj/app │ main [clean] │ initial · "
contains "$(width 200)" "$tilde/work/proj/app │ main [clean] │ initial · "
equals "$(width 40)" "$tilde/work/proj/app │ main [clean]"
equals "$(width 30)" "…/proj/app │ main [clean]"
equals "$(width 24)" "…/app │ main [clean]"

t "ширина: длинное имя ветки обрезается последним"
git -C "$HOME/work/proj/app" checkout -q -b feature/very-long-branch-name
equals "$(width 30)" "…/app │ feature/v… [clean]"
equals "$(width 20)" "…/app │ feature/… [clean]"

t "ширина: некорректный COLUMNS игнорируется"
for bad in 0 19 abc 99999; do
    contains "$(width "$bad")" "$tilde/work/proj/app │ feature/very-long-branch-name [clean] │ initial"
done

t "ширина: строка 2 теряет сегменты с конца, цвета не считаются"
equals "$(line 2 "$(COLUMNS=64 render "$full")")" "M (200K) (high) │ Ctx ━━━━━━━━━━────────── 50% (100K / 200K)"
equals "$(line 2 "$(COLUMNS=63 render "$full")")" "M (200K) (high)"
contains "$(line 2 "$(COLUMNS=64 NO_COLOR='' render "$full")")" "100K / 200K"

# --- стоимость сессии -------------------------------------------------------

# cost_line <json-объект cost> [остальные поля]
cost_line() { line 2 "$(render "{\"model\":{\"display_name\":\"M\"},\"cost\":$1${2:+,$2}}")"; }

t "cost: стоимость, длительность, строки"
equals "$(cost_line '{"total_cost_usd":1.2351,"total_duration_ms":2280000,"total_lines_added":156,"total_lines_removed":23}')" "M │ \$1.24 · 38 мин · +156 −23"
equals "$(STATUSLINE_LANG=en cost_line '{"total_cost_usd":12,"total_duration_ms":3900000}')" "M │ \$12.00 · 1h 5m"
equals "$(cost_line '{"total_cost_usd":0.05,"total_duration_ms":45000}')" "M │ \$0.05 · 45 с"
equals "$(STATUSLINE_LANG=en cost_line '{"total_duration_ms":273600000}')" "M │ 3d 4h"
equals "$(cost_line '{"total_lines_added":0,"total_lines_removed":4}')" "M │ +0 −4"

t "cost: нет данных или нули — нет сегмента"
equals "$(cost_line '{}')" "M"
equals "$(cost_line '{"total_cost_usd":0,"total_duration_ms":0,"total_lines_added":0,"total_lines_removed":0}')" "M"
equals "$(STATUSLINE_HIDE=cost cost_line '{"total_cost_usd":1}')" "M"

t "cost: по подписке сумма в долларах не показывается"
equals "$(cost_line '{"total_cost_usd":1.5,"total_duration_ms":60000}' '"rate_limits":{"five_hour":{"used_percentage":1}}')" "M │ 1 мин"

# --- prompt cache -----------------------------------------------------------

# cache_line <json-объект prompt_cache>
cache_line() { line 2 "$(render "{\"model\":{\"display_name\":\"M\"},\"prompt_cache\":$1}")"; }

t "cache: тёплый кэш — доля попаданий и время остывания"
equals "$(cache_line "{\"caching_observed\":true,\"warm\":true,\"hit_ratio\":0.914,\"expires_at\":$now}")" "M │ Cache 91% · $now_hhmm"
equals "$(cache_line '{"caching_observed":true,"warm":true,"hit_ratio":null,"expires_at":1741635000}')" "M │ Cache 10 мар, 19:30"
equals "$(cache_line '{"caching_observed":true,"warm":true,"hit_ratio":0.5,"expires_at":null}')" "M │ Cache 50%"
equals "$(cache_line '{"caching_observed":true,"warm":true}')" "M │ Cache warm"
equals "$(STATUSLINE_RESET=relative cache_line "{\"caching_observed\":true,\"warm\":true,\"hit_ratio\":1,\"expires_at\":$((now + 270))}")" "M │ Cache 100% · через 4 мин"

t "cache: остывший кэш"
equals "$(cache_line '{"caching_observed":true,"warm":false,"hit_ratio":0.9,"expires_at":null}')" "M │ Cache cold"

t "cache: нет данных, кэширование не наблюдалось, сегмент скрыт"
equals "$(render '{"model":{"display_name":"M"}}' | sed -n 2p)" "M"
equals "$(cache_line '{"caching_observed":false,"warm":false}')" "M"
equals "$(STATUSLINE_HIDE=cache cache_line '{"caching_observed":true,"warm":true}')" "M"

# --- индикаторы режимов -----------------------------------------------------

# mode_line <поля json>
mode_line() { line 2 "$(render "{\"model\":{\"display_name\":\"M\"},\"effort\":{\"level\":\"high\"},$1}")"; }

t "режимы: fast, агент, vim, имя сессии"
equals "$(mode_line '"fast_mode":true')" "M (high) fast"
equals "$(mode_line '"fast_mode":false')" "M (high)"
equals "$(mode_line '"agent":{"name":"security-reviewer"}')" "M (high) @security-reviewer"
equals "$(mode_line '"vim":{"mode":"NORMAL"}')" "M (high) │ NORMAL"
equals "$(mode_line '"session_name":"refactor auth"')" "M (high) │ refactor auth"
equals "$(mode_line '"fast_mode":true,"agent":{"name":"a"},"vim":{"mode":"INSERT"},"session_name":"s"')" "M (high) fast @a │ INSERT │ s"

t "режимы: длинное имя сессии обрезается, управляющие символы убираются"
equals "$(mode_line '"session_name":"a very long session title that goes on and on"')" "M (high) │ a very long session title that…"
equals "$(mode_line '"session_name":"two\nlines\u001b[31m"')" "M (high) │ two lines [31m"
equals "$(render '{"session_name":"two\nlines"}' | wc -l | tr -d ' ')" "2"

t "режимы: каждый скрывается отдельно"
all='"fast_mode":true,"agent":{"name":"a"},"vim":{"mode":"INSERT"},"session_name":"s"'
equals "$(STATUSLINE_HIDE=fast,agent mode_line "$all")" "M (high) │ INSERT │ s"
equals "$(STATUSLINE_HIDE=vim,session mode_line "$all")" "M (high) fast @a"

t "режимы: имя worktree рядом с веткой"
new_repo wt
equals "$(line 1 "$(STATUSLINE_HIDE=commit render "{\"workspace\":{\"current_dir\":\"$REPO\",\"git_worktree\":\"feature-xyz\"}}")")" "$REPO │ main [clean] wt:feature-xyz"
contains "$(render "{\"workspace\":{\"current_dir\":\"$REPO\"},\"worktree\":{\"name\":\"my-feature\"}}")" "main [clean] wt:my-feature"
lacks "$(STATUSLINE_HIDE=worktree render "{\"workspace\":{\"current_dir\":\"$REPO\",\"git_worktree\":\"x\"}}")" "wt:"

# --- ссылки на репозиторий --------------------------------------------------

new_repo linked
git -C "$REPO" checkout -q -b feature/x
# with_repo <host> <owner> <name>
with_repo() { printf '{"workspace":{"current_dir":"%s","repo":{"host":"%s","owner":"%s","name":"%s"}}}' "$REPO" "$1" "$2" "$3"; }
bel=$'\a'
osc() { printf '%s]8;;%s%s%s%s]8;;%s' "$esc" "$1" "$bel" "$2" "$esc" "$bel"; }

t "ссылки: ветка ведёт на GitHub, на других хостах — в корень репозитория"
contains "$(NO_COLOR='' render "$(with_repo github.com o r)")" "$(osc https://github.com/o/r/tree/feature/x feature/x)"
contains "$(NO_COLOR='' render "$(with_repo gitlab.com group/sub r)")" "$(osc https://gitlab.com/group/sub/r feature/x)"

t "ссылки: видимый текст не меняется"
equals "$(line 1 "$(STATUSLINE_HIDE=commit render "$(with_repo github.com o r)")")" "$REPO │ feature/x [clean]"

t "ссылки: нет repo, небезопасные значения, выключено"
lacks "$(NO_COLOR='' render "$(in_dir "$REPO")")" "${esc}]8"
lacks "$(NO_COLOR='' render "$(with_repo github.com 'o r' r)")" "${esc}]8"
lacks "$(NO_COLOR='' render "$(with_repo github.com o '')")" "${esc}]8"
lacks "$(NO_COLOR='' STATUSLINE_HIDE=links render "$(with_repo github.com o r)")" "${esc}]8"
git -C "$REPO" checkout -q -b 'odd#name'
contains "$(NO_COLOR='' render "$(with_repo github.com o r)")" "$(osc https://github.com/o/r 'odd#name')"

# --- pull request -----------------------------------------------------------

new_repo pr
# with_pr <json-объект pr>
with_pr() { printf '{"workspace":{"current_dir":"%s"},"pr":%s}' "$REPO" "$1"; }
pr_line() { line 1 "$(STATUSLINE_HIDE=commit render "$(with_pr "$1")")"; }

t "pr: номер и состояние ревью"
equals "$(pr_line '{"number":12,"url":"https://github.com/o/r/pull/12","review_state":"approved"}')" "$REPO │ main [clean] #12 approved"
contains "$(pr_line '{"number":12,"review_state":"changes_requested"}')" "#12 changes"
contains "$(pr_line '{"number":12,"review_state":"pending"}')" "#12 pending"
contains "$(pr_line '{"number":12,"review_state":"draft"}')" "#12 draft"

t "pr: без состояния, GitLab, отсутствует"
equals "$(pr_line '{"number":12}')" "$REPO │ main [clean] #12"
contains "$(pr_line '{"number":7,"kind":"mr","review_state":"approved"}')" "!7 approved"
lacks "$(render "$(in_dir "$REPO")")" "#"
lacks "$(STATUSLINE_HIDE="pr" render "$(with_pr '{"number":12}')")" "#12"

t "pr: ссылка OSC 8, отключается NO_COLOR и STATUSLINE_HIDE=links"
pr='{"number":12,"url":"https://github.com/o/r/pull/12"}'
contains "$(NO_COLOR='' render "$(with_pr "$pr")")" "${esc}]8;;https://github.com/o/r/pull/12${bel}#12${esc}]8;;${bel}"
lacks "$(render "$(with_pr "$pr")")" "${esc}]8"
lacks "$(NO_COLOR='' STATUSLINE_HIDE=links render "$(with_pr "$pr")")" "${esc}]8"
lacks "$(NO_COLOR='' render "$(with_pr '{"number":12,"url":"javascript:alert(1)"}')")" "${esc}]8"

t "pr: адрес ссылки не учитывается в ширине"
plain=$(line 1 "$(STATUSLINE_HIDE=commit render "$(with_pr "$pr")")")
linked=$(line 1 "$(STATUSLINE_HIDE=commit NO_COLOR='' COLUMNS=$((${#plain} + 4)) render "$(with_pr "$pr")")")
contains "$linked" "$REPO"

t "git: каталог вне репозитория"
mkdir -p "$TMP/plain"
contains "$(render "$(in_dir "$TMP/plain")")" "[no git]"

t "git: чистый репозиторий"
new_repo clean
out=$(line 1 "$(render "$(in_dir "$REPO")")")
contains "$out" "│ main [clean] │ initial · "

t "git: staged, modified, untracked, stash"
new_repo dirty
echo stashed >"$REPO/file"
git -C "$REPO" stash -q
echo a >"$REPO/staged" && git -C "$REPO" add staged
echo two >"$REPO/file"
echo b >"$REPO/new1" && echo c >"$REPO/new2"
out=$(line 1 "$(render "$(in_dir "$REPO")")")
contains "$out" "main +1 ~1 ?2 ≡1 │"
lacks "$out" "[clean]"

t "git: ahead и behind относительно upstream"
new_repo upstream
git clone -q "$REPO" "$TMP/ahead"
git -C "$REPO" commit -q --allow-empty -m remote
git -C "$TMP/ahead" commit -q --allow-empty -m local1
git -C "$TMP/ahead" commit -q --allow-empty -m local2
git -C "$TMP/ahead" fetch -q
contains "$(render "$(in_dir "$TMP/ahead")")" "main [clean] ↑2 ↓1 │"

t "git: конфликт считается конфликтом, а не staged"
new_repo conflict
git -C "$REPO" checkout -q -b other
echo theirs >"$REPO/file" && git -C "$REPO" commit -q -am theirs
git -C "$REPO" checkout -q main
echo ours >"$REPO/file" && git -C "$REPO" commit -q -am ours
git -C "$REPO" merge -q other >/dev/null 2>&1
out=$(line 1 "$(render "$(in_dir "$REPO")")")
contains "$out" "main !1 │"
lacks "$out" "+1"

t "git: detached HEAD показывает короткий хеш"
new_repo detached
sha=$(git -C "$REPO" rev-parse HEAD)
git -C "$REPO" checkout -q --detach
contains "$(render "$(in_dir "$REPO")")" "│ ${sha:0:7} [clean]"

t "git: репозиторий без коммитов"
git init -q -b main "$TMP/empty"
equals "$(line 1 "$(render "$(in_dir "$TMP/empty")")")" "$TMP/empty │ main [clean]"

t "git: тема коммита обрезается по символам, спецсимволы не раскрываются"
new_repo subject 'Длинная тема коммита на русском языке, которая не влезает'
contains "$(render "$(in_dir "$REPO")")" "│ Длинная тема коммита на русском языке, к… · "
new_repo escapes 'fix \n 100%s \033[31m'
contains "$(render "$(in_dir "$REPO")")" '│ fix \n 100%s \033[31m · '

# --- кэш git ----------------------------------------------------------------

new_repo cached
# cached <session_id> [каталог] — строка 1 при включённом кэше
cached() {
    line 1 "$(STATUSLINE_GIT_CACHE=60 STATUSLINE_HIDE=commit render "{\"session_id\":\"$1\",\"workspace\":{\"current_dir\":\"${2:-$REPO}\"}}")"
}
entry="$XDG_CACHE_HOME/claude-statusline/git-s1"

t "кэш git: выключен по умолчанию"
render "{\"session_id\":\"s1\",\"workspace\":{\"current_dir\":\"$REPO\"}}" >/dev/null
if [ -e "$entry" ]; then fail "кэш создан без STATUSLINE_GIT_CACHE"; else ok; fi

t "кэш git: повторный запуск берёт состояние из кэша"
equals "$(cached s1)" "$REPO │ main [clean]"
echo new >"$REPO/untracked"
equals "$(cached s1)" "$REPO │ main [clean]"

t "кэш git: другая сессия, другой каталог, выключенный кэш — свежие данные"
equals "$(cached s2)" "$REPO │ main ?1"
equals "$(cached s1 "$TMP/plain")" "$TMP/plain │ [no git]"
contains "$(render "{\"session_id\":\"s1\",\"workspace\":{\"current_dir\":\"$REPO\"}}")" "main ?1"

t "кэш git: запись устаревает по TTL"
equals "$(cached s1)" "$REPO │ main ?1"
echo newer >"$REPO/untracked2"
equals "$(cached s1)" "$REPO │ main ?1"
sed -i.orig "1s/.*/$(($(date +%s) - 61))/" "$entry"
equals "$(cached s1)" "$REPO │ main ?2"

t "кэш git: повреждённая запись и небезопасный session_id игнорируются"
echo garbage >"$entry"
equals "$(cached s1)" "$REPO │ main ?2"
printf '%s\n' "$(date +%s)" "$REPO" main x 0 0 0 0 0 0 age subject >"$entry"
equals "$(cached s1)" "$REPO │ main ?2"
equals "$(cached '../../evil')" "$REPO │ main ?2"
if [ -e "$TMP/evil" ] || [ -e "$XDG_CACHE_HOME/evil" ]; then fail "запись вне каталога кэша"; else ok; fi

# --- установщик -------------------------------------------------------------

install() { "$BASH" "$INSTALLER" "$@" 2>&1; }

t "install: стандартный каталог, новый settings.json"
out=$(install)
equals "$?" "0"
equals "$(jq -c .statusLine "$HOME/.claude/settings.json")" '{"type":"command","command":"~/.claude/statusline.sh"}'
equals "$("$HOME/.claude/statusline.sh" --version)" "claude-statusline $version"

t "install: существующие настройки сохраняются, делается бэкап"
export CLAUDE_CONFIG_DIR="$TMP/cfg dir"
mkdir -p "$CLAUDE_CONFIG_DIR"
settings="$CLAUDE_CONFIG_DIR/settings.json"
echo '{"theme":"dark","statusLine":{"type":"command","command":"old","padding":2}}' >"$settings"
out=$(install)
equals "$?" "0"
equals "$(jq -r .theme "$settings")" "dark"
equals "$(jq -r .statusLine.padding "$settings")" "2"
equals "$(jq -r .statusLine.command "$settings.bak")" "old"

t "install: команда из settings.json запускается при пробеле в пути"
equals "$(echo '{}' | bash -c "$(jq -r .statusLine.command "$settings")" | wc -l | tr -d ' ')" "2"

t "install: --uninstall убирает скрипт и ключ, остальное не трогает"
out=$(install --uninstall)
equals "$?" "0"
equals "$(jq -c . "$settings")" '{"theme":"dark"}'
if [ -e "$CLAUDE_CONFIG_DIR/statusline.sh" ]; then fail "скрипт не удалён"; else ok; fi

t "install: невалидный settings.json не изменяется"
echo 'not json' >"$settings"
out=$(install)
equals "$?" "1"
equals "$(cat "$settings")" "not json"

t "install: неизвестный флаг"
out=$(install --bogus)
equals "$?" "2"

# ----------------------------------------------------------------------------

printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
