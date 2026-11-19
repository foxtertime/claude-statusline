#!/usr/bin/env bash
# Тесты claude-statusline. Без зависимостей, кроме bash, jq и git.
# Запуск: make test  (или ./tests/run.sh) — оба набора и один общий итог.
#
# Скрипты запускаются тем же bash, что и тесты, поэтому
# `/bin/bash tests/run.sh` на macOS проверяет совместимость с bash 3.2.
#
# Тесты разложены по файлам: tests/lib.sh — окружение и проверки,
# tests/statusline.sh и tests/install.sh — сами тесты.
TESTS_MAIN=1
TESTS_DIR=$(dirname "$0")
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"
# shellcheck source=tests/statusline.sh
. "$TESTS_DIR/statusline.sh"
# shellcheck source=tests/install.sh
. "$TESTS_DIR/install.sh"
finish
