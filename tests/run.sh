#!/usr/bin/env bash
# Тесты claude-statusline. Без зависимостей, кроме bash, jq и git.
# Запуск: make test  (или ./tests/run.sh)
#
# Скрипты запускаются тем же bash, что и тесты, поэтому
# `/bin/bash tests/run.sh` на macOS проверяет совместимость с bash 3.2.
#
# JSON для тестов собирается через printf с форматом в одинарных кавычках.
# Экранированные кавычки (\") внутри "$(...)" bash 3.2 разбирает иначе, чем
# bash 4+, и скрипт получает невалидный JSON.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/src/statusline.sh"
INSTALLER="$ROOT/src/install.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Изолируемся от настроек git и локали разработчика.
export HOME="$TMP/home"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export TZ=UTC NO_COLOR=1
unset CLAUDE_CONFIG_DIR COLUMNS
# Язык задаётся явно: по умолчанию он зависит от локали машины.
export STATUSLINE_LANG=en
unset STATUSLINE_BAR_WIDTH STATUSLINE_WARN STATUSLINE_CRIT STATUSLINE_HIDE
unset STATUSLINE_RESET STATUSLINE_GIT_CACHE
export XDG_CACHE_HOME="$TMP/cache"
mkdir -p "$HOME"

passed=0 failed=0 current=""
esc=$'\033'
tilde='~' # буквальная тильда: в выводе она не раскрывается

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

# --- демо -------------------------------------------------------------------

demo() { "$BASH" "$SCRIPT" --demo; }

t "демо: показывает каждый сегмент и каждую строку лимитов"
out=$(demo)
equals "$?" "0"
for part in "$tilde/projects/app" "feature/auth" "+2" "~1" "?3" "↑1" "≡1" "wt:auth" \
    "#42 approved" "fix(auth): refresh expired tokens" "Opus 5.5 (1M) (high)" "fast" \
    "@reviewer" "Ctx " "62% (620K / 1M)" "43m" "+156 −23" "Cache 91%" "NORMAL" \
    "refactor auth middleware" "Current " "Weekly " "Spend " "\$430 / \$500"; do
    contains "$out" "$part"
done
equals "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "5"

t "демо: учитывает настройки и не читает stdin"
out=$(STATUSLINE_HIDE=commit,limits,session demo </dev/null)
lacks "$out" "fix(auth)"
lacks "$out" "Current"
lacks "$out" "refactor auth"
contains "$(STATUSLINE_LANG=en demo)" "43m"
contains "$(STATUSLINE_RESET=relative demo)" "in 2h 10m"
equals "$(STATUSLINE_HIDE=git demo | sed -n 1p)" "$tilde/projects/app"
lacks "$(demo)" "$esc"

t "демо: ширина терминала"
out=$(COLUMNS=60 demo)
equals "$(line 1 "$out")" "…/app │ feature/auth +2 ~1 ?3 ↑1 ≡1 wt:auth #42 approved"

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

t "поле неверного типа пропадает само, остальные сегменты остаются"
typed='{"model":{"display_name":"M"},"context_window":{"used_percentage":50},"cost":{"total_cost_usd":1},"rate_limits":{"five_hour":{"used_percentage":10}}}'
for field in model effort workspace context_window rate_limits cost pr prompt_cache vim agent; do
    out=$(render "$(printf '%s' "$typed" | jq -c --arg f "$field" '. + {($f): "x"}')")
    case $field in
        model) contains "$out" "? │ Ctx ━━━━━━━━━━────────── 50%" ;;
        context_window) equals "$(line 2 "$out")" "M" ;;
        *) contains "$out" "M │ Ctx ━━━━━━━━━━────────── 50%" ;;
    esac
    [ "$field" = rate_limits ] || contains "$out" "Current "
done
out=$(render '{"rate_limits":{"five_hour":"x","seven_day":{"used_percentage":3}}}')
equals "$(line 3 "$out")" "Weekly  ━─────────────────── 3%"
for doc in '[]' '"x"' '42'; do
    out=$(render "$doc")
    equals "$?" "0"
    contains "$out" "[no git]"
done

t "устаревший cwd используется, если нет workspace.current_dir"
out=$(render '{"cwd":"/legacy"}')
contains "$out" "/legacy │"
out=$(render '{"cwd":"/legacy","workspace":{"current_dir":"/current"}}')
contains "$out" "/current │"

# --- директория -------------------------------------------------------------

t "домашний каталог сокращается до ~"
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
out=$(render "$(printf '{"rate_limits":{"five_hour":{"used_percentage":23.5,"resets_at":%s},"seven_day":{"used_percentage":81.2,"resets_at":1741635000}}}' "$now")")
equals "$(line 3 "$out")" "Current ━━━━━─────────────── 24%  $now_hhmm"
equals "$(line 4 "$out")" "Weekly  ━━━━━━━━━━━━━━━━──── 81%  Mar 10, 19:30"

t "лимиты: окна независимы, resets_at необязателен"
out=$(render '{"rate_limits":{"seven_day":{"used_percentage":5}}}')
equals "$(line 3 "$out")" "Weekly  ━─────────────────── 5%"
lacks "$out" "Current"

t "лимиты: spend_limit с суммами и без, выше 100%"
out=$(render '{"rate_limits":{"spend_limit":{"used_percentage":62.8,"resets_at":1741635000,"used_usd":314.12,"limit_usd":500}}}')
equals "$(line 3 "$out")" "Spend   ━━━━━━━━━━━━━─────── 63%  Mar 10, 19:30  \$314.12 / \$500"
out=$(render '{"rate_limits":{"spend_limit":{"used_percentage":130}}}')
equals "$(line 3 "$out")" "Spend   ━━━━━━━━━━━━━━━━━━━━ 130%"

t "лимиты: суммы spend_limit округляются до центов, не-числа отбрасываются"
spend_usd() { printf '{"rate_limits":{"spend_limit":{"used_percentage":5,"used_usd":%s,"limit_usd":%s}}}' "$1" "$2" | "$BASH" "$SCRIPT" | sed -n 3p; }
equals "$(spend_usd 0.30000000000000004 500)" "Spend   ━─────────────────── 5%  \$0.30 / \$500"
equals "$(spend_usd 0 12.5)" "Spend   ━─────────────────── 5%  \$0 / \$12.50"
out=$(spend_usd '"\u001b]0;pwn\u0007"' 500)
equals "$out" "Spend   ━─────────────────── 5%"
lacks "$out" "$esc"
equals "$(spend_usd -1 500)" "Spend   ━─────────────────── 5%"

t "лимиты: STATUSLINE_RESET=relative — время до сброса"
# Запас в 30 секунд, чтобы результат не зависел от момента запуска.
resets_in() { printf '{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":%s}}}' "$(($(date +%s) + $1))"; }
relative() { line 3 "$(STATUSLINE_RESET=relative render "$(resets_in "$1")")"; }
equals "$(relative 7830)" "Current ━─────────────────── 5%  in 2h 10m"
equals "$(relative 273630)" "Current ━─────────────────── 5%  in 3d 4h"
equals "$(relative 330)" "Current ━─────────────────── 5%  in 5m"
equals "$(relative 20)" "Current ━─────────────────── 5%  in <1m"
equals "$(relative -500)" "Current ━─────────────────── 5%  in <1m"
equals "$(STATUSLINE_LANG=en relative 7830)" "Current ━─────────────────── 5%  in 2h 10m"
equals "$(STATUSLINE_LANG=en relative 20)" "Current ━─────────────────── 5%  in <1m"
resets_now=$(printf '{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":%s}}}' "$now")
equals "$(line 3 "$(STATUSLINE_RESET=bogus render "$resets_now")")" "Current ━─────────────────── 5%  $now_hhmm"

t "лимиты: встроенное форматирование времени совпадает с date"
# На bash 4.2+ время форматирует printf '%(...)T', на bash 3.2 — date;
# _STATUSLINE_FORCE_DATE включает путь через date и на новом bash.
for zone in UTC Asia/Tokyo America/Los_Angeles; do
    for ts in "$now" $((now + 3 * 86400)) 1741635000 1767225599; do
        json=$(printf '{"rate_limits":{"five_hour":{"used_percentage":5,"resets_at":%s}}}' "$ts")
        builtin=$(printf '%s' "$json" | TZ=$zone "$BASH" "$SCRIPT")
        fallback=$(printf '%s' "$json" | TZ=$zone _STATUSLINE_FORCE_DATE=1 "$BASH" "$SCRIPT")
        equals "$builtin" "$fallback"
    done
done
equals "$(line 3 "$(_STATUSLINE_FORCE_DATE=1 render '{"rate_limits":{"seven_day":{"used_percentage":5,"resets_at":1741635000}}}')")" "Weekly  ━─────────────────── 5%  Mar 10, 19:30"

t "лимиты: seven_day_sonnet больше не выводится"
lacks "$(render '{"rate_limits":{"seven_day_sonnet":{"used_percentage":8}}}')" "Sonnet"

# --- настройки --------------------------------------------------------------

full='{"model":{"display_name":"M"},"effort":{"level":"high"},"context_window":{"used_percentage":50,"total_input_tokens":100000,"context_window_size":200000},"rate_limits":{"five_hour":{"used_percentage":10},"seven_day":{"used_percentage":20,"resets_at":1741635000},"spend_limit":{"used_percentage":30}}}'

t "настройки: STATUSLINE_LANG"
contains "$(STATUSLINE_LANG=en render "$full")" "20%  Mar 10, 19:30"
contains "$(STATUSLINE_LANG=ru render "$full")" "20%  10 мар, 19:30"

t "настройки: язык по умолчанию берётся из локали"
# with_locale <VAR=значение>... — запуск без STATUSLINE_LANG и с заданной локалью
with_locale() {
    printf '%s' "$full" |
        env -u STATUSLINE_LANG -u LC_ALL -u LC_TIME -u LANG "$@" "$BASH" "$SCRIPT" 2>/dev/null
}
ru_date="20%  10 мар, 19:30" en_date="20%  Mar 10, 19:30"
contains "$(with_locale LANG=ru_RU.UTF-8)" "$ru_date"
contains "$(with_locale LANG=en_US.UTF-8)" "$en_date"
contains "$(with_locale LANG=de_DE.UTF-8)" "$en_date"
contains "$(with_locale)" "$en_date"
contains "$(with_locale LANG=C)" "$en_date"
contains "$(with_locale LANG=en_US.UTF-8 LC_TIME=ru_RU.UTF-8)" "$ru_date"
contains "$(with_locale LANG=ru_RU.UTF-8 LC_TIME=en_GB.UTF-8)" "$en_date"
contains "$(with_locale LC_ALL=en_US.UTF-8 LC_TIME=ru_RU.UTF-8)" "$en_date"
contains "$(with_locale LANG=rw_RW.UTF-8)" "$en_date"

t "настройки: STATUSLINE_LANG важнее локали, некорректное значение игнорируется"
contains "$(with_locale LANG=en_US.UTF-8 STATUSLINE_LANG=ru)" "$ru_date"
contains "$(with_locale LANG=ru_RU.UTF-8 STATUSLINE_LANG=en)" "$en_date"
contains "$(with_locale LANG=ru_RU.UTF-8 STATUSLINE_LANG=xx)" "$ru_date"

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

t "ширина: путь без / не превращается в многоточие"
equals "$(line 1 "$(COLUMNS=20 render '{}')")" "? │ [no git]"
equals "$(line 1 "$(COLUMNS=20 render '{"cwd":"relative"}')")" "relative │ [no git]"

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

t "ширина: ветка не отрастает обратно, когда убираются worktree и PR"
git init -q -b feature/very-long-branch-name-for-testing-truncation "$TMP/long/app"
git -C "$TMP/long/app" commit -q --allow-empty -m initial
touch "$TMP/long/app/new"
long=$(printf '{"workspace":{"current_dir":"%s"},"worktree":{"name":"wt1"},"pr":{"number":12}}' "$TMP/long/app")
equals "$(line 1 "$(COLUMNS=34 render "$long")")" "…/app │ feature/very-long-… ?1"
equals "$(line 1 "$(COLUMNS=30 render "$long")")" "…/app │ feature/very-l… ?1"
equals "$(line 1 "$(COLUMNS=24 render "$long")")" "…/app │ feature/… ?1"
equals "$(line 1 "$(COLUMNS=40 render "$long")")" "…/app │ feature/very-… ?1 wt:wt1 #12"

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
cost_line() {
    local json
    json=$(printf '{"model":{"display_name":"M"},"cost":%s%s}' "$1" "${2:+,$2}")
    line 2 "$(render "$json")"
}

t "cost: стоимость, длительность, строки"
equals "$(cost_line '{"total_cost_usd":1.2351,"total_duration_ms":2280000,"total_lines_added":156,"total_lines_removed":23}')" "M │ \$1.24 · 38m · +156 −23"
equals "$(STATUSLINE_LANG=en cost_line '{"total_cost_usd":12,"total_duration_ms":3900000}')" "M │ \$12.00 · 1h 5m"
equals "$(cost_line '{"total_cost_usd":0.05,"total_duration_ms":45000}')" "M │ \$0.05 · 45s"
equals "$(STATUSLINE_LANG=en cost_line '{"total_duration_ms":273600000}')" "M │ 3d 4h"
equals "$(cost_line '{"total_lines_added":0,"total_lines_removed":4}')" "M │ +0 −4"

t "cost: нет данных или нули — нет сегмента"
equals "$(cost_line '{}')" "M"
equals "$(cost_line '{"total_cost_usd":0,"total_duration_ms":0,"total_lines_added":0,"total_lines_removed":0}')" "M"
equals "$(STATUSLINE_HIDE=cost cost_line '{"total_cost_usd":1}')" "M"

t "cost: по подписке сумма в долларах не показывается"
equals "$(cost_line '{"total_cost_usd":1.5,"total_duration_ms":60000}' '"rate_limits":{"five_hour":{"used_percentage":1}}')" "M │ 1m"

# --- prompt cache -----------------------------------------------------------

# cache_line <json-объект prompt_cache>
cache_line() {
    local json
    json=$(printf '{"model":{"display_name":"M"},"prompt_cache":%s}' "$1")
    line 2 "$(render "$json")"
}
# warm_until <epoch> — тёплый кэш с заданным временем остывания
warm_until() { printf '{"caching_observed":true,"warm":true,"hit_ratio":0.914,"expires_at":%s}' "$1"; }

t "cache: тёплый кэш — доля попаданий и время остывания"
equals "$(cache_line "$(warm_until "$now")")" "M │ Cache 91% · $now_hhmm"
equals "$(cache_line '{"caching_observed":true,"warm":true,"hit_ratio":null,"expires_at":1741635000}')" "M │ Cache Mar 10, 19:30"
equals "$(cache_line '{"caching_observed":true,"warm":true,"hit_ratio":0.5,"expires_at":null}')" "M │ Cache 50%"
equals "$(cache_line '{"caching_observed":true,"warm":true}')" "M │ Cache warm"
equals "$(STATUSLINE_RESET=relative cache_line "$(warm_until $((now + 270)))")" "M │ Cache 91% · in 4m"

t "cache: остывший кэш"
equals "$(cache_line '{"caching_observed":true,"warm":false,"hit_ratio":0.9,"expires_at":null}')" "M │ Cache cold"

t "cache: нет данных, кэширование не наблюдалось, сегмент скрыт"
equals "$(render '{"model":{"display_name":"M"}}' | sed -n 2p)" "M"
equals "$(cache_line '{"caching_observed":false,"warm":false}')" "M"
equals "$(STATUSLINE_HIDE=cache cache_line '{"caching_observed":true,"warm":true}')" "M"

# --- индикаторы режимов -----------------------------------------------------

# mode_line <поля json>
mode_line() {
    local json
    json=$(printf '{"model":{"display_name":"M"},"effort":{"level":"high"},%s}' "$1")
    line 2 "$(render "$json")"
}

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
git_wt=$(printf '{"workspace":{"current_dir":"%s","git_worktree":"feature-xyz"}}' "$REPO")
session_wt=$(printf '{"workspace":{"current_dir":"%s"},"worktree":{"name":"my-feature"}}' "$REPO")
equals "$(line 1 "$(STATUSLINE_HIDE=commit render "$git_wt")")" "$REPO │ main [clean] wt:feature-xyz"
contains "$(render "$session_wt")" "main [clean] wt:my-feature"
lacks "$(STATUSLINE_HIDE=worktree render "$git_wt")" "wt:"

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
lacks "$(NO_COLOR='' render "$(in_dir "$REPO")")" "${esc}]8;;http"
lacks "$(NO_COLOR='' render "$(with_repo github.com 'o r' r)")" "${esc}]8;;http"
lacks "$(NO_COLOR='' render "$(with_repo github.com o '')")" "${esc}]8;;http"
lacks "$(NO_COLOR='' STATUSLINE_HIDE=links render "$(with_repo github.com o r)")" "${esc}]8"
git -C "$REPO" checkout -q -b 'odd#name'
contains "$(NO_COLOR='' render "$(with_repo github.com o r)")" "$(osc https://github.com/o/r 'odd#name')"

t "ссылки: директория ведёт на file:// с полным путём"
host=$(printf '%s' "$HOSTNAME" | LC_ALL=C sed 's/[^A-Za-z0-9.-]//g')
[ "${host}" = "$HOSTNAME" ] || host=""
contains "$(NO_COLOR='' render "$(in_dir "${REPO}")")" "$(osc "file://${host}${REPO}" "${REPO}")"
# на узком экране путь сокращён, а ссылка — на полный путь
contains "$(NO_COLOR='' COLUMNS=30 render "$(in_dir "${REPO}")")" "]8;;file://${host}${REPO}${bel}…/"
mkdir -p "${TMP}/a b#c%d/проект"
contains "$(NO_COLOR='' render "$(in_dir "${TMP}/a b#c%d/проект")")" "]8;;file://${host}${TMP}/a%20b%23c%25d/%D0%BF%D1%80%D0%BE%D0%B5%D0%BA%D1%82${bel}"
equals "$(line 1 "$(render "$(in_dir "${TMP}/a b#c%d/проект")")")" "${TMP}/a b#c%d/проект │ [no git]"

t "ссылки: директория — управляющие символы кодируются, без ссылки, если путь не абсолютный"
out=$(NO_COLOR='' render '{"workspace":{"current_dir":"/tmp/x\u001b]0;pwn\u0007y"}}')
contains "$out" "]8;;file://${host}/tmp/x%1B%5D0%3Bpwn%07y${bel}"
lacks "$out" "${esc}]0;pwn"
lacks "$(NO_COLOR='' render '{}')" "${esc}]8"
lacks "$(NO_COLOR='' render '{"workspace":{"current_dir":"relative"}}')" "${esc}]8"
lacks "$(NO_COLOR='' STATUSLINE_HIDE=links render "$(in_dir "${REPO}")")" "${esc}]8"
lacks "$(render "$(in_dir "${REPO}")")" "${esc}]8"

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
out=$(NO_COLOR='' render "$(with_pr '{"number":12,"url":"javascript:alert(1)"}')")
lacks "$out" "javascript"
lacks "$out" "${bel}#12"

t "pr: адрес ссылки не учитывается в ширине"
plain=$(line 1 "$(STATUSLINE_HIDE=commit render "$(with_pr "$pr")")")
linked=$(line 1 "$(STATUSLINE_HIDE=commit NO_COLOR='' COLUMNS=$((${#plain} + 4)) render "$(with_pr "$pr")")")
contains "$linked" "$REPO"

# width <строка> — ширина в колонках терминала (широкие символы — две)
cols() { python3 -I -c 'import sys,unicodedata as u; s=sys.argv[1]; print(sum(2 if u.east_asian_width(c) in "WF" else 1 for c in s))' "$1"; }

t "ширина: STATUSLINE_PADDING уменьшает доступную ширину на 2 × padding"
equals "$(width 30)" "…/app │ feature/v… [clean]"
equals "$(line 1 "$(COLUMNS=36 STATUSLINE_PADDING=3 render "$app")")" "…/app │ feature/v… [clean]"
equals "$(line 1 "$(COLUMNS=30 STATUSLINE_PADDING=abc render "$app")")" "…/app │ feature/v… [clean]"

t "ширина: широкие символы занимают две колонки"
mkdir -p "$TMP/data/项目"
equals "$(line 1 "$(COLUMNS=22 render "$(in_dir "$TMP/data/项目")")")" "…/项目 │ [no git]"
# Подгонка включается с COLUMNS ≥ 20, поэтому строки здесь длиннее.
rockets='{"model":{"display_name":"M"},"session_name":"🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀"}'
equals "$(line 2 "$(COLUMNS=26 render "$rockets")")" "M"
equals "$(line 2 "$(COLUMNS=28 render "$rockets")")" "M │ 🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀"
equals "$(line 2 "$(COLUMNS=26 render '{"model":{"display_name":"M"},"session_name":"абвгдежзийклмнопрс"}')")" "M │ абвгдежзийклмнопрс"

t "ширина: строки лимитов теряют примечание, время сброса, затем укорачивают шкалу"
spend='{"rate_limits":{"spend_limit":{"used_percentage":86,"resets_at":1741635000,"used_usd":430,"limit_usd":500}}}'
equals "$(line 3 "$(render "$spend")")" "Spend   ━━━━━━━━━━━━━━━━━─── 86%  Mar 10, 19:30  \$430 / \$500"
equals "$(line 3 "$(COLUMNS=51 render "$spend")")" "Spend   ━━━━━━━━━━━━━━━━━─── 86%  Mar 10, 19:30"
equals "$(line 3 "$(COLUMNS=50 render "$spend")")" "Spend   ━━━━━━━━━━━━━━━━━─── 86%"
equals "$(line 3 "$(COLUMNS=40 render "$spend")")" "Spend   ━━━━━━━━━━━━━━━━━─── 86%"
equals "$(line 3 "$(COLUMNS=30 render "$spend")")" "Spend   ━━━━━━━━━━━━── 86%"
equals "$(line 3 "$(COLUMNS=20 render "$spend")")" "Spend   ━━━━─ 86%"

t "ширина: ни одна строка демо не шире доступной"
# Ниже ~40 колонок самый короткий вариант строки может не влезть — тогда её
# обрежет сам Claude Code.
for c in 40 50 60 80 120; do
    for opts in "" "STATUSLINE_LANG=ru" "STATUSLINE_ASCII=1" "STATUSLINE_PADDING=2"; do
        max=$((c - 4))
        case $opts in STATUSLINE_PADDING=2) max=$((c - 8)) ;; esac
        while IFS= read -r row; do
            w=$(cols "$row")
            if [ "$w" -gt "$max" ]; then fail "COLUMNS=$c $opts: $w > $max" "$row"; else ok; fi
        done <<<"$(env $opts COLUMNS=$c "$BASH" "$SCRIPT" --demo)"
    done
done

t "ширина: сегмент модели теряет агента, fast и effort последними"
head='{"model":{"display_name":"Opus"},"effort":{"level":"high"},"fast_mode":true,"agent":{"name":"rev"},"context_window":{"used_percentage":5}}'
equals "$(line 2 "$(COLUMNS=30 render "$head")")" "Opus (high) fast @rev"
equals "$(line 2 "$(COLUMNS=24 render "$head")")" "Opus (high) fast"
equals "$(line 2 "$(COLUMNS=20 STATUSLINE_PADDING=1 render "$head")")" "Opus (high)"
equals "$(line 2 "$(COLUMNS=20 STATUSLINE_PADDING=3 render "$head")")" "Opus"
equals "$(line 2 "$(render "$head")")" "Opus (high) fast @rev │ Ctx ━─────────────────── 5%"

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
    local json
    json=$(printf '{"session_id":"%s","workspace":{"current_dir":"%s"}}' "$1" "${2:-$REPO}")
    line 1 "$(STATUSLINE_GIT_CACHE=60 STATUSLINE_HIDE=commit render "$json")"
}
uncached=$(printf '{"session_id":"s1","workspace":{"current_dir":"%s"}}' "$REPO")
entry="$XDG_CACHE_HOME/claude-statusline/git-s1"

t "кэш git: выключен по умолчанию"
render "$uncached" >/dev/null
if [ -e "$entry" ]; then fail "кэш создан без STATUSLINE_GIT_CACHE"; else ok; fi

t "кэш git: повторный запуск берёт состояние из кэша"
equals "$(cached s1)" "$REPO │ main [clean]"
echo new >"$REPO/untracked"
equals "$(cached s1)" "$REPO │ main [clean]"

t "кэш git: другая сессия, другой каталог, выключенный кэш — свежие данные"
equals "$(cached s2)" "$REPO │ main ?1"
equals "$(cached s1 "$TMP/plain")" "$TMP/plain │ [no git]"
contains "$(render "$uncached")" "main ?1"

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

# --- раскладка --------------------------------------------------------------

layout() { STATUSLINE_LAYOUT=$1 "$BASH" "$SCRIPT" --demo; }

t "раскладка: по умолчанию вывод не меняется"
equals "$(layout '')" "$(demo)"
equals "$(layout 'context,cost,cache,vim,session')" "$(demo)"

t "раскладка: порядок сегментов, неназванные — следом в обычном порядке"
equals "$(line 2 "$(layout 'cache,context')" | sed 's/ │ /|/g' | cut -d'|' -f2-)" \
    "$(line 2 "$(demo)" | sed 's/ │ /|/g' | awk -F'|' '{print $4 "|" $2 "|" $3 "|" $5 "|" $6}')"
contains "$(line 2 "$(layout 'session')")" "@reviewer │ refactor auth middleware │ Ctx "

t "раскладка: / переносит сегменты на отдельную строку перед лимитами"
out=$(layout 'context,cost/cache,vim,session')
equals "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "6"
contains "$(line 2 "$out")" "62% (620K / 1M) │ 43m · +156 −23"
lacks "$(line 2 "$out")" "Cache"
equals "$(line 3 "$out" | cut -d'│' -f2-)" " NORMAL │ refactor auth middleware"
contains "$(line 3 "$out")" "Cache 91%"
contains "$(line 4 "$out")" "Current "
equals "$(line 3 "$(layout 'context/cost')" | cut -c1-3)" "43m"

t "раскладка: пустая отдельная строка не печатается, ширина соблюдается"
out=$(STATUSLINE_HIDE=cache,vim,session layout 'context,cost/cache,vim,session')
equals "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "5"
out=$(COLUMNS=40 layout 'context/cost,cache,vim,session')
contains "$(line 3 "$out")" "43m · +156 −23"
lacks "$(line 3 "$out")" "refactor"

t "раскладка: неизвестные имена и повторы игнорируются"
equals "$(layout 'bogus,context/zzz')" "$(demo)"
equals "$(layout 'context,context,cost')" "$(demo)"
equals "$(layout '///')" "$(demo)"

t "раскладка: compact — одна строка"
out=$(layout compact)
equals "$out" "…/app │ feature/auth +2 ~1 ?3 │ Opus 5.5 (1M) (high) │ Ctx 62% │ 5h 34% │ 7d 71% │ Spend 86%"
equals "$(COLUMNS=66 layout compact)" "…/app │ feature/auth +2 ~1 ?3 │ Opus 5.5 (1M) (high) │ Ctx 62%"
equals "$(COLUMNS=60 layout compact)" "…/app │ feature/auth +2 ~1 ?3 │ Opus 5.5 (1M) (high)"
equals "$(STATUSLINE_HIDE=limits layout compact)" "…/app │ feature/auth +2 ~1 ?3 │ Opus 5.5 (1M) (high) │ Ctx 62%"
equals "$(STATUSLINE_HIDE=weekly,git layout compact)" "…/app │ Opus 5.5 (1M) (high) │ Ctx 62% │ 5h 34% │ Spend 86%"
equals "$(STATUSLINE_LANG=ru layout compact | cut -d'│' -f4-)" " Контекст 62% │ 5ч 34% │ 7д 71% │ Расход 86%"
contains "$(NO_COLOR='' layout compact)" "${esc}[33m62%"
equals "$(printf '{}' | STATUSLINE_LAYOUT=compact "$BASH" "$SCRIPT")" "? │ [no git] │ ?"

# --- русский режим, цвета, ASCII --------------------------------------------

ru() { STATUSLINE_LANG=ru "$@"; }

t "русский режим: все подписи переведены"
out=$(ru demo)
for part in "#42 одобрен" "быстро" "Контекст " "43 мин" "Кэш 91%" "2 часа назад" \
    "Сейчас " "Неделя " "Расход "; do
    contains "$out" "$part"
done
for word in Ctx Cache Current Weekly Spend approved fast cold warm clean "no git"; do
    lacks "$out" "$word"
done

t "русский режим: прочие подписи, даты и длительности"
contains "$(ru render "$(in_dir "$TMP")")" "[нет git]"
new_repo ru_clean
contains "$(ru render "$(in_dir "$REPO")")" "main [чисто]"
contains "$(ru render '{"prompt_cache":{"caching_observed":true,"warm":false}}')" "Кэш остыл"
contains "$(ru render '{"prompt_cache":{"caching_observed":true,"warm":true}}')" "Кэш тёплый"
for state in "changes_requested правки" "pending ждёт" "draft черновик"; do
    contains "$(ru render "$(printf '{"workspace":{"current_dir":"%s"},"pr":{"number":1,"review_state":"%s"}}' "$REPO" "${state%% *}")")" "#1 ${state#* }"
done
equals "$(line 3 "$(ru render '{"rate_limits":{"seven_day":{"used_percentage":5,"resets_at":1741635000}}}')")" "Неделя ━─────────────────── 5%  10 мар, 19:30"
equals "$(line 3 "$(ru env STATUSLINE_RESET=relative "$BASH" "$SCRIPT" <<<"$(resets_in 7830)")")" "Сейчас ━─────────────────── 5%  через 2 ч 10 мин"
equals "$(ru cost_line '{"total_duration_ms":273600000}')" "M │ 3 д 4 ч"
equals "$(ru cost_line '{"total_duration_ms":45000}')" "M │ 45 с"

t "русский режим: столбец подписей лимитов выровнен"
out=$(ru demo)
for n in 3 4 5; do
    row=$(line "$n" "$out")
    equals "${row:6:1}" " "
    equals "${row:7:1}" "━"
done

t "цвета: светлая тема и переопределение ролей"
coloured() { NO_COLOR='' "$@" "$BASH" "$SCRIPT" --demo; }
contains "$(coloured env)" "${esc}[2;37m"
contains "$(coloured env STATUSLINE_THEME=light)" "${esc}[90m"
lacks "$(coloured env STATUSLINE_THEME=light)" "${esc}[2;37m"
contains "$(coloured env STATUSLINE_COLOR_DIR='1;34' STATUSLINE_HIDE=links)" "${esc}[1;34m$tilde/projects/app"
contains "$(coloured env STATUSLINE_COLOR_OK=92)" "${esc}[92m+2"
contains "$(coloured env STATUSLINE_COLOR_WARN=93)" "${esc}[93m━"
equals "$(coloured env STATUSLINE_COLOR_DIR='1;34m;rm -rf' STATUSLINE_THEME=bogus)" "$(coloured env)"
equals "$(NO_COLOR=1 STATUSLINE_COLOR_DIR='1;34' demo)" "$(demo)"

t "ASCII: только ASCII-символы, кроме данных пользователя"
out=$(STATUSLINE_ASCII=1 demo)
non_ascii=$(printf '%s' "$out" | LC_ALL=C grep -c '[^ -~]')
equals "$non_ascii" "0"
contains "$(line 1 "$out")" "$tilde/projects/app | feature/auth +2 ~1 ?3 ^1 =1"
contains "$out" "Current ###"
contains "$out" "+156 -23"
contains "$(STATUSLINE_ASCII=1 COLUMNS=60 demo)" "./app |"
equals "$(STATUSLINE_ASCII=0 demo)" "$(demo)"

# --- управляющие символы ----------------------------------------------------

t "управляющие символы в теме коммита и пути не попадают в вывод"
new_repo ctrl "$(printf 'evil \033[2J\033]0;pwned\007 subject')"
out=$(line 1 "$(render "$(in_dir "$REPO")")")
contains "$out" "│ evil  [2J ]0;pwned  subject · "
lacks "$out" "$esc"
lacks "$out" $'\a'
odd="$TMP/odd$(printf '\033')[31mdir"
mkdir -p "$odd"
git init -q -b main "$odd"
out=$(render "$(jq -nc --arg d "$odd" '{workspace:{current_dir:$d}}')")
contains "$out" "odd [31mdir │ main [clean]"
lacks "$out" "$esc"

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

t "install: --set, --refresh и --padding пишут настройки"
export CLAUDE_CONFIG_DIR="$TMP/opts"
settings="$CLAUDE_CONFIG_DIR/settings.json"
out=$(install --set STATUSLINE_LANG=ru --set "STATUSLINE_HIDE=commit,spend" --refresh 60 --padding 2)
equals "$?" "0"
equals "$(jq -c .env "$settings")" '{"STATUSLINE_LANG":"ru","STATUSLINE_HIDE":"commit,spend","STATUSLINE_PADDING":"2"}'
equals "$(jq -c '[.statusLine.refreshInterval, .statusLine.padding]' "$settings")" '[60,2]'
contains "$out" "после перезапуска"

t "install: повторная установка сохраняет опции, --unset и 0 их убирают"
install >/dev/null
equals "$(jq -c .env "$settings")" '{"STATUSLINE_LANG":"ru","STATUSLINE_HIDE":"commit,spend","STATUSLINE_PADDING":"2"}'
install --unset STATUSLINE_HIDE --refresh 0 --padding 0 >/dev/null
equals "$(jq -c .env "$settings")" '{"STATUSLINE_LANG":"ru"}'
equals "$(jq -c '.statusLine | keys' "$settings")" '["command","type"]'
install --unset STATUSLINE_LANG >/dev/null
equals "$(jq -c 'has("env")' "$settings")" "false"

t "install: STATUSLINE_PADDING следует за statusLine.padding, заданным вручную"
jq '.statusLine.padding = 3' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
install >/dev/null
equals "$(jq -r .env.STATUSLINE_PADDING "$settings")" "3"

t "install: некорректные настройки отклоняются, файл не меняется"
before=$(cat "$settings")
for args in "--set BOGUS=1" "--set STATUSLINE_BOGUS=1" "--set STATUSLINE_LANG" \
    "--set STATUSLINE_PADDING=2" "--unset LANG" "--refresh x" "--padding -1" \
    "--check --set STATUSLINE_LANG=en" "--uninstall --refresh 5"; do
    # shellcheck disable=SC2086  # аргументы разделяются намеренно
    out=$(install $args)
    if [ "$?" -eq 1 ]; then ok; else fail "ожидался код 1: $args" "$out"; fi
done
out=$(install --set "STATUSLINE_LANG BAR_WIDTH=1")
if [ "$?" -eq 1 ]; then ok; else fail "ожидался код 1: имя с пробелом" "$out"; fi
equals "$(cat "$settings")" "$before"

t "install: --uninstall убирает и опции, чужие env не трогает"
jq '.env.OTHER = "keep"' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
install --set STATUSLINE_LANG=en --refresh 30 >/dev/null
install --uninstall >/dev/null
equals "$(jq -c . "$settings")" '{"env":{"OTHER":"keep"}}'

t "install: --check"
install >/dev/null
out=$(install --check)
equals "$?" "0"
contains "$out" "Проблем не найдено."
contains "$out" "установлена версия $version"
jq '.env.STATUSLINE_BOGUS = "1" | .statusLine.padding = 2' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
out=$(install --check)
equals "$?" "0"
contains "$out" "[внимание] неизвестная опция STATUSLINE_BOGUS"
contains "$out" "STATUSLINE_PADDING = 0"
contains "$out" "исправит $INSTALLER"
rm "$CLAUDE_CONFIG_DIR/statusline.sh"
out=$(install --check)
equals "$?" "1"
contains "$out" "не найден или не исполняемый"
echo 'not json' >"$settings"
out=$(install --check)
equals "$?" "1"
contains "$out" "не валидный JSON"

t "install: --set знает все опции статуслайна"
# shellcheck disable=SC2016  # ищем текст «${STATUSLINE_…» в скрипте
read_options=$(grep -o '\${STATUSLINE_[A-Z_]*' "$SCRIPT" | sed 's/^\${STATUSLINE_//' | grep -v '^PADDING$' | sort -u)
roles=$(sed -n 's/^ *for role in \(.*\); do$/\1/p' "$SCRIPT")
export CLAUDE_CONFIG_DIR="$TMP/all-options"
mkdir -p "$CLAUDE_CONFIG_DIR"
for option in $read_options $(for role in $roles; do echo "COLOR_$role"; done); do
    if out=$(install --set "STATUSLINE_$option=1"); then ok; else fail "--set STATUSLINE_$option отклонён" "$out"; fi
done
out=$(install --check)
for option in $read_options; do
    contains "$out" "опция STATUSLINE_$option=1"
done
lacks "$out" "неизвестная опция"

t "install: без копии репозитория скачивает релиз и сверяет SHA256SUMS"
release="$TMP/release" standalone="$TMP/standalone"
mkdir -p "$release" "$standalone"
cp "$SCRIPT" "$release/statusline.sh"
cp "$INSTALLER" "$standalone/install.sh"
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
(cd "$release" && sha statusline.sh >SHA256SUMS)
export CLAUDE_CONFIG_DIR="$TMP/downloaded"
out=$(STATUSLINE_DOWNLOAD_BASE="file://$release" "$BASH" "$standalone/install.sh" 2>&1)
equals "$?" "0"
if cmp -s "$SCRIPT" "$CLAUDE_CONFIG_DIR/statusline.sh"; then ok; else fail "скачанный файл отличается"; fi
echo "# подмена" >>"$release/statusline.sh"
rm -rf "$CLAUDE_CONFIG_DIR"
out=$(STATUSLINE_DOWNLOAD_BASE="file://$release" "$BASH" "$standalone/install.sh" 2>&1)
equals "$?" "1"
contains "$out" "контрольная сумма"
if [ -e "$CLAUDE_CONFIG_DIR" ]; then fail "при неверной сумме что-то записано"; else ok; fi
out=$(STATUSLINE_RELEASE=main "$BASH" "$standalone/install.sh" 2>&1)
equals "$?" "1"

t "install: чужой statusline.sh рядом с установщиком не ставится без проверки"
cp "$SCRIPT" "$release/statusline.sh" # вернуть файл после проверки подмены
printf '#!/bin/sh\necho "claude-statusline 0.0-stale"\n' >"$standalone/statusline.sh"
export CLAUDE_CONFIG_DIR="$TMP/stale"
out=$(STATUSLINE_DOWNLOAD_BASE="file://$release" "$BASH" "$standalone/install.sh" 2>&1)
equals "$?" "0"
if cmp -s "$SCRIPT" "$CLAUDE_CONFIG_DIR/statusline.sh"; then ok; else fail "установлен не скачанный файл" "$out"; fi
lacks "$out" "0.0-stale"

t "install: запуск из каталога настроек"
cp "$INSTALLER" "$CLAUDE_CONFIG_DIR/install.sh"
before=$(cat "$CLAUDE_CONFIG_DIR/settings.json")
out=$(STATUSLINE_DOWNLOAD_BASE="file://$release" "$BASH" "$CLAUDE_CONFIG_DIR/install.sh" 2>&1)
equals "$?" "0"
lacks "$out" "same file"
equals "$(cat "$CLAUDE_CONFIG_DIR/settings.json")" "$before"

t "install: каталог настроек — сама копия репозитория"
mkdir -p "$TMP/repo-copy/tests" "$TMP/repo-copy/src"
cp "$INSTALLER" "$SCRIPT" "$TMP/repo-copy/src/" && touch "$TMP/repo-copy/tests/run.sh"
export CLAUDE_CONFIG_DIR="$TMP/repo-copy/src"
out=$("$BASH" "$CLAUDE_CONFIG_DIR/install.sh" 2>&1)
equals "$?" "1"
contains "$out" "это и есть установленный скрипт"
if [ -e "$CLAUDE_CONFIG_DIR/settings.json" ]; then fail "settings.json создан"; else ok; fi

# ----------------------------------------------------------------------------

printf '%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
