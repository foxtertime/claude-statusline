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

now=$(date +%s)
t "лимиты: время сброса сегодня и в другой день"
out=$(render "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":23.5,\"resets_at\":$now},\"seven_day\":{\"used_percentage\":81.2,\"resets_at\":1741635000}}}")
equals "$(line 3 "$out")" "Current ━━━━━─────────────── 24%  $(date +%H:%M)"
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
