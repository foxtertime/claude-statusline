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

- **Строка 1** — текущая директория; git-ветка (или короткий хеш в detached HEAD) с индикаторами: конфликты (`!`), staged (`+`), modified (`~`), untracked (`?`), ahead/behind (`↑`/`↓`), stash (`≡`), имя git worktree (`wt:имя`), открытый pull request ветки с состоянием ревью (`#123 approved`, для GitLab — `!123`) — ссылкой, если терминал их поддерживает, — тема и возраст последнего коммита. Чистое дерево — `[clean]`, вне репозитория — `[no git]`.
- **Строка 2** — модель, размер контекстного окна, уровень effort, отметка `fast` в быстром режиме и `@имя` агента; шкала заполнения контекста с процентом и токенами; сессия: оценка стоимости, длительность и число добавленных и удалённых строк (`$1.24 · 38 мин · +156 −23`). Стоимость — оценка Claude Code по прайс-листу, а не счёт; по подписке она не показывается. В конце — состояние кэша промпта: `Cache 91% · 19:30` — доля чтений из кэша и время, когда он остынет, или `Cache cold`, если следующий запрос будет прочитан заново целиком. Последними идут режим vim (`NORMAL` / `INSERT`) и имя сессии.
- **Строки 3+** — лимиты использования, по строке на каждое окно, которое передаёт Claude Code:
  - `Current` — 5-часовое окно, `Weekly` — недельное (подписки Pro, Max и Ultra);
  - `Spend` — лимит расходов за шлюзом Claude apps, с суммами в долларах, если шлюз их сообщает.

  Время сброса — в 24-часовом формате: «19:30», если сегодня, иначе «10 мар, 19:30».

Шкалы зелёные до 50 %, жёлтые до 80 %, дальше красные — пороги [настраиваются](#настройка).

Статуслайн подстраивается под ширину терминала. Если строка 1 не помещается, из неё по очереди убираются тема последнего коммита, начало пути (`…/proj/app`, затем `…/app`) и хвост имени ветки (`feature/lo…`). Строка 2 теряет сегменты с конца.

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

## Настройка

Статуслайн настраивается переменными окружения. Задать их можно в блоке `env` файла `~/.claude/settings.json`:

```json
"env": { "STATUSLINE_LANG": "en", "STATUSLINE_HIDE": "commit,spend" }
```

или прямо в команде: `"command": "STATUSLINE_LANG=en ~/.claude/statusline.sh"`.

| Переменная | По умолчанию | Значение |
| --- | --- | --- |
| `STATUSLINE_LANG` | `ru` | Язык дат и единиц времени: `ru` или `en` |
| `STATUSLINE_BAR_WIDTH` | `20` | Ширина шкал в символах, от 5 до 60 |
| `STATUSLINE_WARN` | `50` | Процент, с которого шкала жёлтая |
| `STATUSLINE_CRIT` | `80` | Процент, с которого шкала красная |
| `STATUSLINE_HIDE` | — | Список скрываемых сегментов через запятую |
| `STATUSLINE_RESET` | `absolute` | Время сброса лимита: `absolute` — «19:30», `relative` — «через 2 ч 10 мин» |
| [`NO_COLOR`](https://no-color.org) | — | Любое непустое значение отключает цвета и ссылки |

Сегменты для `STATUSLINE_HIDE`:

| Сегмент | Что скрывает |
| --- | --- |
| `git` | весь git-блок |
| `commit` | тему и возраст последнего коммита |
| `pr` | pull request текущей ветки |
| `links` | кликабельные ссылки (OSC 8); текст остаётся |
| `worktree` | имя git worktree |
| `effort` | уровень effort |
| `fast` | отметку быстрого режима |
| `agent` | имя агента |
| `context` | шкалу контекста |
| `tokens` | счётчик токенов рядом со шкалой |
| `cost` | стоимость, длительность и строки сессии |
| `cache` | состояние кэша промпта |
| `vim` | режим vim |
| `session` | имя сессии |
| `limits` | все строки лимитов |
| `current`, `weekly`, `spend` | отдельную строку лимита |

Некорректное значение игнорируется — используется значение по умолчанию.

Claude Code перерисовывает статуслайн после сообщений, а не по таймеру, поэтому с `STATUSLINE_RESET=relative` оставшееся время устаревает, пока сессия простаивает. Чтобы оно обновлялось, задайте интервал в секундах рядом с командой:

```json
"statusLine": { "type": "command", "command": "~/.claude/statusline.sh", "refreshInterval": 60 }
```

Установщик это поле не добавляет, но и не удаляет при обновлении.

Режим vim Claude Code показывает и сам — строкой `-- INSERT --` под полем ввода. Чтобы он не дублировался, добавьте в `statusLine` поле `"hideVimModeIndicator": true` либо скройте сегмент: `STATUSLINE_HIDE=vim`.

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
