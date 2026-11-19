# shellcheck shell=bash
# Переменные отсюда используются в подключающих файлах.
# shellcheck disable=SC2034
# Общая часть тестов: изолированное окружение и проверки. Подключается из
# tests/run.sh, tests/statusline.sh и tests/install.sh.
#
# JSON для тестов собирается через printf с форматом в одинарных кавычках.
# Экранированные кавычки (\") внутри "$(...)" bash 3.2 разбирает иначе, чем
# bash 4+, и скрипт получает невалидный JSON.
set -u
TESTS_LIB=1

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
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

# Версия статуслайна — с ней сверяются --version и установщик.
version=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$SCRIPT")

# finish — итог; код возврата ненулевой, если что-то упало
finish() {
    printf '%d passed, %d failed\n' "$passed" "$failed"
    [ "$failed" -eq 0 ]
}
