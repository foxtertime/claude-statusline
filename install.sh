#!/usr/bin/env bash
# Установка statusline для Claude Code.
# Запуск: ./install.sh
set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
SETTINGS="$CLAUDE_DIR/settings.json"
SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/statusline.sh"

# Обязательные зависимости
missing=()
for dep in jq bc; do
    command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Не хватает зависимостей: ${missing[*]}" >&2
    echo "Установите их, например: sudo dnf install ${missing[*]}  (или apt install)" >&2
    exit 1
fi

# git — опционален: без него просто не будет git-блока в статуслайне
if ! command -v git >/dev/null 2>&1; then
    echo "Предупреждение: git не найден — ветка и статус репозитория показываться не будут." >&2
fi

mkdir -p "$CLAUDE_DIR"
cp "$SCRIPT_SRC" "$CLAUDE_DIR/statusline.sh"
chmod +x "$CLAUDE_DIR/statusline.sh"

# Прописываем statusLine в settings.json, не трогая остальные настройки
if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "$SETTINGS.bak"
    jq '.statusLine = {"type": "command", "command": "~/.claude/statusline.sh"}' \
        "$SETTINGS.bak" > "$SETTINGS"
    echo "Обновлён $SETTINGS (бэкап: $SETTINGS.bak)"
else
    printf '%s\n' '{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}' > "$SETTINGS"
    echo "Создан $SETTINGS"
fi

echo "Готово. Перезапустите Claude Code — statusline появится."
