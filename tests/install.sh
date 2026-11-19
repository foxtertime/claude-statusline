#!/usr/bin/env bash
# Тесты установщика (src/install.sh). Запуск отдельно: ./tests/install.sh; все тесты — ./tests/run.sh
# shellcheck source=tests/lib.sh
[ -n "${TESTS_LIB:-}" ] || . "$(dirname "$0")/lib.sh"

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
equals "$(jq -r .statusLine.command "$settings.orig")" "old"
install --set STATUSLINE_LANG=ru >/dev/null
install --set STATUSLINE_LANG=en >/dev/null
equals "$(jq -r .env.STATUSLINE_LANG "$settings.bak")" "ru"
equals "$(jq -c . "$settings.orig")" '{"theme":"dark","statusLine":{"type":"command","command":"old","padding":2}}'
install --unset STATUSLINE_LANG >/dev/null

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

t "install: settings.json-ссылка остаётся ссылкой, права сохраняются"
export CLAUDE_CONFIG_DIR="$TMP/linked"
mkdir -p "$CLAUDE_CONFIG_DIR" "$TMP/dotfiles"
echo '{"theme":"dark"}' >"$TMP/dotfiles/settings.json"
chmod 644 "$TMP/dotfiles/settings.json"
ln -s "$TMP/dotfiles/settings.json" "$CLAUDE_CONFIG_DIR/settings.json"
out=$(install --set STATUSLINE_LANG=ru)
equals "$?" "0"
if [ -L "$CLAUDE_CONFIG_DIR/settings.json" ]; then ok; else fail "ссылка заменена обычным файлом"; fi
equals "$(jq -r '.theme + " " + .env.STATUSLINE_LANG' "$TMP/dotfiles/settings.json")" "dark ru"
equals "$(find "$TMP/dotfiles/settings.json" -perm 644)" "$TMP/dotfiles/settings.json"
install --uninstall >/dev/null
if [ -L "$CLAUDE_CONFIG_DIR/settings.json" ]; then ok; else fail "--uninstall заменил ссылку"; fi
equals "$(jq -c . "$TMP/dotfiles/settings.json")" '{"theme":"dark"}'
leftovers=("$CLAUDE_CONFIG_DIR"/settings.json.*)
equals "${leftovers[*]}" "$CLAUDE_CONFIG_DIR/settings.json.bak $CLAUDE_CONFIG_DIR/settings.json.orig"

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

t "install: 00 считается нулём, ведущие нули отбрасываются"
install --refresh 030 --padding 02 >/dev/null
equals "$(jq -c '[.statusLine.refreshInterval, .statusLine.padding, .env.STATUSLINE_PADDING]' "$settings")" '[30,2,"2"]'
install --refresh 00 --padding 00 >/dev/null
equals "$(jq -c '.statusLine | keys' "$settings")" '["command","type"]'
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

t "install: переустановка сохраняет опции перед командой"
export CLAUDE_CONFIG_DIR="$TMP/prefixed"
settings="$CLAUDE_CONFIG_DIR/settings.json"
install >/dev/null
cmd=$(jq -r .statusLine.command "$settings")
jq --arg c "STATUSLINE_LANG=en $cmd" '.statusLine.command = $c' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
install --refresh 5 >/dev/null
equals "$(jq -r .statusLine.command "$settings")" "STATUSLINE_LANG=en $cmd"
out=$(install --check)
equals "$?" "0"
lacks "$out" "команда отличается"
jq '.statusLine.command = "other.sh"' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
install >/dev/null
equals "$(jq -r .statusLine.command "$settings")" "$cmd"
jq --arg c "STATUSLINE_LANG=en $cmd.old" '.statusLine.command = $c' "$settings" >"$settings.tmp" && mv "$settings.tmp" "$settings"
install >/dev/null
equals "$(jq -r .statusLine.command "$settings")" "$cmd"

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

[ -n "${TESTS_MAIN:-}" ] || finish
