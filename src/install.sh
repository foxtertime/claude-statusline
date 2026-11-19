#!/usr/bin/env bash
# Установка, настройка и удаление claude-statusline.
#
#   install.sh [настройки]        установить или обновить
#   install.sh --check            проверить установку
#   install.sh --uninstall        удалить скрипт и его настройки
#
# В копии репозитория установщик лежит в src/ (или: make install).
#
# Настройки (можно повторять и сочетать):
#   --set STATUSLINE_X=значение   задать опцию статуслайна
#   --unset STATUSLINE_X          убрать опцию
#   --refresh N                   перерисовывать каждые N секунд (0 — выключить)
#   --padding N                   отступ statusLine.padding (0 — убрать)
#
# Каталог настроек берётся из CLAUDE_CONFIG_DIR, по умолчанию ~/.claude.
# Вне копии репозитория statusline.sh скачивается из релиза на
# GitHub (STATUSLINE_RELEASE=vX.Y.Z, по умолчанию последний) и сверяется с
# SHA256SUMS того же релиза.
set -euo pipefail

REPO_URL="https://github.com/foxtertime/claude-statusline"
DEFAULT_DIR="$HOME/.claude"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$DEFAULT_DIR}"
SETTINGS="$CLAUDE_DIR/settings.json"
TARGET="$CLAUDE_DIR/statusline.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
# Копия репозитория узнаётся по src/statusline.sh и tests/run.sh: так
# statusline.sh, случайно оказавшийся рядом со скачанным установщиком, не
# ставится без проверки.
SOURCE=""
[ -f "$HERE/statusline.sh" ] && [ -f "$HERE/../tests/run.sh" ] && SOURCE="$HERE/statusline.sh"
# Как запустить установщик снова — для подсказок в сообщениях
SELF=$0

# Опции, которые принимает --set. STATUSLINE_PADDING не входит: его
# установщик выставляет сам по statusLine.padding (см. --padding).
KNOWN_OPTIONS="LANG BAR_WIDTH WARN CRIT HIDE RESET GIT_CACHE THEME ASCII LAYOUT
    COLOR_DIR COLOR_MUTED COLOR_MODEL COLOR_TEXT COLOR_OK COLOR_WARN COLOR_CRIT
    COLOR_ACCENT"

# known_option <KEY> — KEY есть в KNOWN_OPTIONS. Имя сравнивается целиком,
# поэтому перевод строки в списке и пробел в имени ничего не ломают.
known_option() {
    local name
    case $1 in STATUSLINE_*) ;; *) return 1 ;; esac
    for name in $KNOWN_OPTIONS; do
        [ "STATUSLINE_$name" = "$1" ] && return 0
    done
    return 1
}

# В settings.json пишем ~/.claude/..., пока каталог стандартный: такой файл
# можно переносить между машинами.
if [ "$CLAUDE_DIR" = "$DEFAULT_DIR" ]; then
    # shellcheck disable=SC2088  # тильду раскрывает Claude Code, а не мы
    COMMAND="~/.claude/statusline.sh"
else
    # Команду запускает shell, поэтому путь с пробелами нужно экранировать.
    printf -v COMMAND '%q' "$TARGET"
fi

die() {
    echo "Ошибка: $*" >&2
    exit 1
}

usage() {
    sed -n '2,/^set -euo/{/^set -euo/d;s/^# \{0,1\}//p;}' "$0"
}

# update_settings <jq-фильтр> [аргументы jq...]
# jq пишет во временный файл: при сбое settings.json остаётся нетронутым.
# Результат копируется поверх старого файла, а не переносится через mv: так
# символическая ссылка (менеджеры dotfiles) и права файла сохраняются.
update_settings() {
    local tmp
    tmp=$(mktemp "$SETTINGS.XXXXXX")
    if ! jq "$@" "$SETTINGS" >"$tmp"; then
        rm -f "$tmp"
        die "$SETTINGS — не валидный JSON, файл не изменён"
    fi
    # .orig — файл до первого изменения установщиком, не перезаписывается;
    # .bak — версия перед последним запуском.
    [ -e "$SETTINGS.orig" ] || cp "$SETTINGS" "$SETTINGS.orig"
    cp "$SETTINGS" "$SETTINGS.bak"
    cat "$tmp" >"$SETTINGS"
    rm -f "$tmp"
}

require_jq() {
    command -v jq >/dev/null 2>&1 || die "не найден jq — установите его (apt/dnf/brew install jq)"
}

# --- скачивание -------------------------------------------------------------

# download <url> <файл>
download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$2" "$1"
    else
        die "для скачивания нужен curl или wget"
    fi
}

# sha256 <файл> — контрольная сумма
sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# fetch_source — вне копии репозитория скачать statusline.sh из релиза
fetch_source() {
    [ -n "$SOURCE" ] && return 0

    local release=${STATUSLINE_RELEASE:-latest} base
    case $release in
        latest) base="$REPO_URL/releases/latest/download" ;;
        v[0-9]*.[0-9]*.[0-9]*) base="$REPO_URL/releases/download/$release" ;;
        *) die "STATUSLINE_RELEASE: ожидается latest или vX.Y.Z, получено '$release'" ;;
    esac
    base=${STATUSLINE_DOWNLOAD_BASE:-$base}

    local dir
    dir=$(mktemp -d)
    # shellcheck disable=SC2064  # путь подставляется сейчас, это и нужно
    trap "rm -rf '$dir'" EXIT
    echo "Скачиваю statusline.sh ($release)…"
    download "$base/statusline.sh" "$dir/statusline.sh" || die "не удалось скачать $base/statusline.sh"
    download "$base/SHA256SUMS" "$dir/SHA256SUMS" || die "не удалось скачать $base/SHA256SUMS"

    local expected actual
    expected=$(awk '$2 == "statusline.sh" || $2 == "*statusline.sh" { print $1 }' "$dir/SHA256SUMS")
    actual=$(sha256 "$dir/statusline.sh")
    [ -n "$expected" ] || die "в SHA256SUMS нет записи для statusline.sh"
    [ "$expected" = "$actual" ] || die "контрольная сумма statusline.sh не совпадает — файл не установлен"
    SOURCE="$dir/statusline.sh"
}

# --- настройки --------------------------------------------------------------

SETS='{}'
UNSETS='[]'
REFRESH=""
PADDING=""

# add_set <KEY=VALUE>
add_set() {
    local key=${1%%=*} value=${1#*=}
    [ "$key" != "$1" ] || die "--set: ожидается STATUSLINE_X=значение, получено '$1'"
    [ "$key" = STATUSLINE_PADDING ] &&
        die "STATUSLINE_PADDING выставляется сам по statusLine.padding — используйте --padding"
    known_option "$key" || die "неизвестная опция '$key'; список — в README"
    SETS=$(jq -n --argjson o "$SETS" --arg k "$key" --arg v "$value" '$o + {($k): $v}')
}

# add_unset <KEY>
add_unset() {
    case $1 in
        STATUSLINE_*) ;;
        *) die "--unset: ожидается имя STATUSLINE_X, получено '$1'" ;;
    esac
    UNSETS=$(jq -n --argjson a "$UNSETS" --arg k "$1" '$a + [$k]')
}

# number_arg <флаг> <значение> — неотрицательное целое; в REPLY оно же без
# ведущих нулей, чтобы 00 считалось нулём
number_arg() {
    case $2 in
        '' | *[!0-9]*) die "$1: ожидается неотрицательное целое, получено '$2'" ;;
    esac
    REPLY=${2#"${2%%[!0]*}"}
    REPLY=${REPLY:-0}
}

# Переносит настройки в settings.json. STATUSLINE_PADDING всегда следует за
# statusLine.padding: Claude Code не передаёт отступ скрипту, а без него
# строки с отступом не помещаются.
# shellcheck disable=SC2016  # $cmd, $sets и т. д. — переменные jq
SETTINGS_FILTER='
    (.statusLine.command // "") as $old
    # Команду с опциями впереди (STATUSLINE_LANG=en ~/.claude/statusline.sh)
    # оставляем как есть, чтобы переустановка не стирала эти опции.
    | (if ($old | type) == "string" and ($old | endswith(" " + $cmd))
       then $old else $cmd end) as $command
    | .statusLine = ((.statusLine // {}) + {type: "command", command: $command})
    | if $refresh == "" then .
      elif $refresh == "0" then del(.statusLine.refreshInterval)
      else .statusLine.refreshInterval = ($refresh | tonumber) end
    | if $padding == "" then .
      elif $padding == "0" then del(.statusLine.padding)
      else .statusLine.padding = ($padding | tonumber) end
    | .env = ((.env // {}) + $sets)
    | reduce $unsets[] as $k (.; del(.env[$k]))
    | (.statusLine.padding // 0) as $p
    | if ($p | type) == "number" and $p > 0
      then .env.STATUSLINE_PADDING = ($p | tostring)
      else del(.env.STATUSLINE_PADDING) end
    | if .env == {} then del(.env) else . end
'

# --- действия ---------------------------------------------------------------

do_install() {
    require_jq
    fetch_source
    [ "$SOURCE" -ef "$TARGET" ] && die "$SOURCE — это и есть установленный скрипт; запустите установщик из копии репозитория или скачанный отдельно"

    mkdir -p "$CLAUDE_DIR"
    local args=(--arg cmd "$COMMAND" --arg refresh "$REFRESH" --arg padding "$PADDING"
        --argjson sets "$SETS" --argjson unsets "$UNSETS")
    if [ -f "$SETTINGS" ]; then
        update_settings "${args[@]}" "$SETTINGS_FILTER"
        echo "Обновлён $SETTINGS (бэкап: $SETTINGS.bak, исходный файл: $SETTINGS.orig)"
    else
        jq -n "${args[@]}" "{} | $SETTINGS_FILTER" >"$SETTINGS"
        echo "Создан $SETTINGS"
    fi

    cp "$SOURCE" "$TARGET"
    chmod +x "$TARGET"

    command -v git >/dev/null 2>&1 ||
        echo "Предупреждение: git не найден — git-блок показываться не будет." >&2

    echo "Установлено: $("$TARGET" --version)"
    if [ "$SETS$UNSETS" != '{}[]' ] || [ -n "$PADDING" ]; then
        echo "Настройки из блока env применяются после перезапуска Claude Code."
    fi
    echo "Готово. Если статуслайн не появился — перезапустите Claude Code."
}

do_uninstall() {
    require_jq
    # Сначала настройки: статуслайн не должен ссылаться на удалённый файл.
    if [ -f "$SETTINGS" ]; then
        update_settings '
            del(.statusLine)
            | if .env then .env |= with_entries(select(.key | startswith("STATUSLINE_") | not)) else . end
            | if .env == {} then del(.env) else . end'
        echo "Ключ statusLine и опции STATUSLINE_* удалены из $SETTINGS (бэкап: $SETTINGS.bak, исходный файл: $SETTINGS.orig)"
    fi
    rm -f "$TARGET"
    echo "claude-statusline удалён."
}

# --- проверка ---------------------------------------------------------------

PROBLEMS=0

report() {
    local mark=$1
    shift
    case $mark in
        ok) printf '  [ок]       %s\n' "$*" ;;
        warn) printf '  [внимание] %s\n' "$*" ;;
        fail)
            printf '  [ошибка]   %s\n' "$*"
            PROBLEMS=$((PROBLEMS + 1))
            ;;
    esac
}

# version_of <строка> — первое число вида X.Y из строки
version_of() {
    printf '%s\n' "$1" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1
}

# version_lt <a> <b> — a < b (сравнение X.Y)
version_lt() {
    local a_major=${1%%.*} b_major=${2%%.*} a_rest=${1#*.} b_rest=${2#*.}
    local a_minor=${a_rest%%.*} b_minor=${b_rest%%.*}
    [ "$a_major" -lt "$b_major" ] || { [ "$a_major" -eq "$b_major" ] && [ "$a_minor" -lt "$b_minor" ]; }
}

do_check() {
    echo "Проверка claude-statusline"

    report ok "bash $BASH_VERSION"

    if command -v jq >/dev/null 2>&1; then
        report ok "$(jq --version)"
    else
        report fail "jq не найден — без него статуслайн не работает"
    fi

    if command -v git >/dev/null 2>&1; then
        local git_version
        git_version=$(version_of "$(git --version)")
        if version_lt "$git_version" 2.15; then
            report warn "git $git_version: нужен 2.15+, иначе git-блок не показывается"
        elif version_lt "$git_version" 2.35; then
            report warn "git $git_version: счётчик stash появится с git 2.35"
        else
            report ok "git $git_version"
        fi
    else
        report warn "git не найден — git-блок показываться не будет"
    fi

    if [ ! -f "$SETTINGS" ]; then
        report fail "$SETTINGS не найден — запустите $SELF"
    elif ! command -v jq >/dev/null 2>&1; then
        :
    elif ! jq empty "$SETTINGS" 2>/dev/null; then
        report fail "$SETTINGS — не валидный JSON"
    else
        check_settings
    fi

    if [ "$PROBLEMS" -eq 0 ]; then
        echo "Проблем не найдено."
    else
        echo "Найдено проблем: $PROBLEMS."
        return 1
    fi
}

check_settings() {
    local type command
    type=$(jq -r '.statusLine.type // ""' "$SETTINGS")
    command=$(jq -r '.statusLine.command // ""' "$SETTINGS")
    if [ -z "$command" ]; then
        report fail "в $SETTINGS нет statusLine.command — запустите $SELF"
        return
    fi
    [ "$type" = command ] || report fail "statusLine.type = '$type', ожидается 'command'"
    report ok "statusLine.command: $command"

    local script=$TARGET
    if [ "$command" != "$COMMAND" ] && [ "${command% "$COMMAND"}" = "$command" ]; then
        report warn "команда отличается от той, что ставит установщик ($COMMAND)"
        # Чужая команда: берём последнее слово и раскрываем ~ сами.
        script=${command##* }
        case $script in
            \~/*) script="$HOME/${script#\~/}" ;;
        esac
    fi
    if [ ! -x "$script" ]; then
        report fail "$script не найден или не исполняемый"
        return
    fi

    local installed
    installed=$("$script" --version 2>/dev/null | cut -d' ' -f2)
    if [ -n "$SOURCE" ]; then
        local available
        available=$("$BASH" "$SOURCE" --version 2>/dev/null | cut -d' ' -f2)
        if [ "$installed" = "$available" ]; then
            report ok "установлена версия $installed"
        else
            report warn "установлена версия $installed, в этой копии репозитория — $available; обновить: $SELF"
        fi
    else
        report ok "установлена версия $installed"
    fi

    local lines
    if lines=$(printf '{}' | "$script" 2>&1) && [ -n "$lines" ]; then
        report ok "пробный запуск: скрипт выводит строки и завершается без ошибок"
    else
        report fail "пробный запуск завершился ошибкой: $lines"
    fi

    local key value
    while IFS=$'\t' read -r key value; do
        [ -n "$key" ] || continue
        if known_option "$key"; then
            report ok "опция $key=$value"
        elif [ "$key" != STATUSLINE_PADDING ]; then
            report warn "неизвестная опция $key — статуслайн её не читает"
        fi
    done < <(jq -r '(.env // {}) | to_entries[] | select(.key | startswith("STATUSLINE_")) | "\(.key)\t\(.value)"' "$SETTINGS")

    local padding env_padding
    padding=$(jq -r '.statusLine.padding // 0' "$SETTINGS")
    env_padding=$(jq -r '.env.STATUSLINE_PADDING // "0"' "$SETTINGS")
    if [ "$padding" != "$env_padding" ]; then
        report warn "statusLine.padding = $padding, а STATUSLINE_PADDING = $env_padding — строки могут обрезаться; исправит $SELF"
    fi
}

# --- разбор аргументов ------------------------------------------------------

ACTION=install
while [ $# -gt 0 ]; do
    case $1 in
        --uninstall) ACTION=uninstall ;;
        --check) ACTION=check ;;
        -h | --help)
            usage
            exit 0
            ;;
        --set)
            [ $# -ge 2 ] || die "--set: нужно значение"
            require_jq
            add_set "$2"
            shift
            ;;
        --unset)
            [ $# -ge 2 ] || die "--unset: нужно имя опции"
            require_jq
            add_unset "$2"
            shift
            ;;
        --refresh)
            [ $# -ge 2 ] || die "--refresh: нужно число секунд"
            number_arg --refresh "$2"
            REFRESH=$REPLY
            shift
            ;;
        --padding)
            [ $# -ge 2 ] || die "--padding: нужно число"
            number_arg --padding "$2"
            PADDING=$REPLY
            shift
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [ "$ACTION" != install ] && { [ "$SETS$UNSETS" != '{}[]' ] || [ -n "$REFRESH$PADDING" ]; }; then
    die "настройки задаются только при установке, без --check и --uninstall"
fi

case $ACTION in
    install) do_install ;;
    uninstall) do_uninstall ;;
    check) do_check ;;
esac
