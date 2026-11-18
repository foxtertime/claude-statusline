#!/usr/bin/env bash
# Установка и удаление claude-statusline.
#
#   ./install.sh              установить или обновить
#   ./install.sh --uninstall  удалить скрипт и ключ statusLine
#
# Каталог настроек берётся из CLAUDE_CONFIG_DIR, по умолчанию ~/.claude.
set -euo pipefail

DEFAULT_DIR="$HOME/.claude"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$DEFAULT_DIR}"
SETTINGS="$CLAUDE_DIR/settings.json"
TARGET="$CLAUDE_DIR/statusline.sh"
SOURCE="$(cd "$(dirname "$0")" && pwd)/statusline.sh"

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
    sed -n '2,7s/^# \{0,1\}//p' "$0"
}

# update_settings <jq-фильтр> [аргументы jq...]
# Пишет через временный файл: при сбое jq settings.json остаётся нетронутым.
update_settings() {
    local tmp
    tmp=$(mktemp "$SETTINGS.XXXXXX")
    if ! jq "$@" "$SETTINGS" >"$tmp"; then
        rm -f "$tmp"
        die "$SETTINGS — не валидный JSON, файл не изменён"
    fi
    cp "$SETTINGS" "$SETTINGS.bak"
    mv "$tmp" "$SETTINGS"
}

require_jq() {
    command -v jq >/dev/null 2>&1 || die "не найден jq — установите его (apt/dnf/brew install jq)"
}

do_install() {
    require_jq
    [ -f "$SOURCE" ] || die "не найден $SOURCE"

    mkdir -p "$CLAUDE_DIR"
    if [ -f "$SETTINGS" ]; then
        # Сохраняем остальные поля statusLine (padding, refreshInterval).
        # shellcheck disable=SC2016  # $cmd — переменная jq
        update_settings --arg cmd "$COMMAND" \
            '.statusLine = ((.statusLine // {}) + {type: "command", command: $cmd})'
        echo "Обновлён $SETTINGS (бэкап: $SETTINGS.bak)"
    else
        jq -n --arg cmd "$COMMAND" '{statusLine: {type: "command", command: $cmd}}' >"$SETTINGS"
        echo "Создан $SETTINGS"
    fi

    cp "$SOURCE" "$TARGET"
    chmod +x "$TARGET"

    command -v git >/dev/null 2>&1 ||
        echo "Предупреждение: git не найден — git-блок показываться не будет." >&2

    echo "Установлено: $("$TARGET" --version)"
    echo "Готово. Если статуслайн не появился — перезапустите Claude Code."
}

do_uninstall() {
    require_jq
    # Сначала настройки: статуслайн не должен ссылаться на удалённый файл.
    if [ -f "$SETTINGS" ]; then
        update_settings 'del(.statusLine)'
        echo "Ключ statusLine удалён из $SETTINGS (бэкап: $SETTINGS.bak)"
    fi
    rm -f "$TARGET"
    echo "claude-statusline удалён."
}

case ${1:-} in
    "") do_install ;;
    --uninstall) do_uninstall ;;
    -h | --help) usage ;;
    *)
        usage >&2
        exit 2
        ;;
esac
