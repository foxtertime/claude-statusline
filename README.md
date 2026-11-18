# claude-statusline

[![CI](https://github.com/foxtertime/claude-statusline/actions/workflows/ci.yml/badge.svg)](https://github.com/foxtertime/claude-statusline/actions/workflows/ci.yml)

Статуслайн для [Claude Code](https://claude.com/claude-code): директория, git-ветка со статусом, модель с размером контекста и уровнем effort, шкала заполнения контекста и лимиты использования с временем сброса на русском.

```
~/projects/app │ main +2 ~1 ?3 ↑1 ≡1 │ fix(api): retry on 429 · 2 hours ago
Opus 5 (1M) (high) │ Ctx ━━────────────────── 12% (125K / 1M)
Current ━━━━━─────────────── 24%  02:40
Weekly  ━━━━━━━━──────────── 41%  4 сен, 12:00
```

Что показывается:

- **Строка 1** — текущая директория; git-ветка (или короткий хеш в detached HEAD) с индикаторами: конфликты (`!`), staged (`+`), modified (`~`), untracked (`?`), ahead/behind (`↑`/`↓`), stash (`≡`), тема и возраст последнего коммита. Чистое дерево — `[clean]`, вне репозитория — `[no git]`.
- **Строка 2** — модель, размер контекстного окна, уровень effort; шкала заполнения контекста с процентом и токенами.
- **Строки 3+** — лимиты использования, по строке на каждое окно, которое передаёт Claude Code:
  - `Current` — 5-часовое окно, `Weekly` — недельное (подписки Pro, Max и Ultra);
  - `Spend` — лимит расходов за шлюзом Claude apps, с суммами в долларах, если шлюз их сообщает.

  Время сброса — в 24-часовом формате: «19:30», если сегодня, иначе «10 мар, 19:30».

Шкалы зелёные до 50 %, жёлтые до 80 %, дальше красные. Цвета отключаются переменной [`NO_COLOR`](https://no-color.org).

Блоки появляются по мере того, как Claude Code присылает данные: шкала контекста и лимиты — после первого ответа API в сессии.

## Установка

```bash
git clone https://github.com/foxtertime/claude-statusline.git
cd claude-statusline && ./install.sh
```

Установщик кладёт скрипт в `~/.claude/statusline.sh` и добавляет в `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }
```

Остальные настройки не затрагиваются, включая соседние поля `statusLine` (`padding`, `refreshInterval`); прежний файл сохраняется в `settings.json.bak`. Если задана переменная `CLAUDE_CONFIG_DIR`, установка идёт в неё.

Обновление:

```bash
git pull && ./install.sh
```

Удаление:

```bash
./install.sh --uninstall
```

## Зависимости

- Обязательно: `bash` 3.2+, [`jq`](https://jqlang.org)
- Опционально: `git` 2.15+ — без него не отображается git-блок (счётчик stash требует git 2.35+)

Работает на Linux и macOS (GNU и BSD `date`).

## Проверка

Установленная версия:

```bash
~/.claude/statusline.sh --version
```

Запуск вручную на тестовых данных:

```bash
echo '{"model":{"display_name":"Opus"},"workspace":{"current_dir":"'"$PWD"'"},"context_window":{"used_percentage":25,"context_window_size":200000}}' | ./statusline.sh
```

## Разработка

```bash
make check   # shellcheck, shfmt и тесты — то же, что запускает CI
make hooks   # включить проверку сообщений коммитов
```

Ветвление по Gitflow, коммиты по Conventional Commits, версии по SemVer — подробности и порядок выпуска релиза в [CONTRIBUTING.md](CONTRIBUTING.md). История изменений — в [CHANGELOG.md](CHANGELOG.md).

## Лицензия

[MIT](LICENSE)
