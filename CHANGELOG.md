# Changelog

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии — [SemVer](https://semver.org/lang/ru/).

## [Unreleased]

### Добавлено
- Сегмент сессии в строке 2: оценка стоимости, длительность, добавленные и удалённые строки ([#6](https://github.com/foxtertime/claude-statusline/issues/6)).
- Открытый pull request текущей ветки рядом с веткой: номер, состояние ревью и ссылка; merge request GitLab — как `!123` ([#5](https://github.com/foxtertime/claude-statusline/issues/5)).
- Строки подстраиваются под ширину терминала (`COLUMNS`): строка 1 по шагам теряет тему коммита, начало пути и хвост имени ветки, строка 2 — сегменты с конца ([#3](https://github.com/foxtertime/claude-statusline/issues/3)).
- Настройка переменными окружения: `STATUSLINE_LANG` (язык дат), `STATUSLINE_BAR_WIDTH`, `STATUSLINE_WARN` / `STATUSLINE_CRIT` (пороги цвета) и `STATUSLINE_HIDE` (скрытие сегментов) ([#4](https://github.com/foxtertime/claude-statusline/issues/4)).

## [1.1.1] — 2026-11-18

Сам статуслайн и установщик не изменились.

### Изменено
- Workflow `Release` можно запустить вручную для существующего тега; если релиз уже опубликован, обновляется его описание.
- Порядок выпуска: тег пушится отдельной командой после веток.
- В `CLAUDE.md` закреплено ведение задач в GitHub Issues.

## [1.1.0] — 2026-11-18

### Добавлено
- Строка `Spend` — лимит расходов за шлюзом Claude apps (`rate_limits.spend_limit`), с суммами в долларах, если шлюз их сообщает.
- Поддержка `NO_COLOR`.
- Время сброса лимитов на macOS (BSD `date`).
- `install.sh --uninstall` и установка в каталог из `CLAUDE_CONFIG_DIR`.
- Тесты, `Makefile`, CI (shellcheck, shfmt, тесты на Linux и macOS), автоматическая публикация релиза по тегу.
- `CONTRIBUTING.md` и `CLAUDE.md`: Gitflow, Conventional Commits, порядок выпуска релиза.

### Изменено
- Скрипт переписан: один вызов `jq` вместо тринадцати и один `git status --porcelain=v2` вместо пяти вызовов git — отрисовка примерно в четыре раза быстрее.
- Рабочая директория берётся из `workspace.current_dir`; `cwd` остаётся запасным вариантом.
- Токены контекста показываются в одном формате: `125K / 1M` вместо `125K / 1000K`.
- Обрезанная тема коммита помечается многоточием.
- Установщик сохраняет соседние поля `statusLine` (`padding`, `refreshInterval`) и пишет `settings.json` через временный файл.

### Удалено
- Строка `Sonnet` (`rate_limits.seven_day_sonnet`): такого поля в данных статуслайна Claude Code нет.
- Зависимость от `bc`.
- Размер контекста `200K` «по умолчанию», когда настоящий размер неизвестен.

### Исправлено
- Обратные слэши в пути, имени ветки или теме коммита раскрывались как escape-последовательности.
- Конфликтующие файлы считались ещё и как staged; конфликты вида `DU`/`UD` не считались вовсе.
- `~` подставлялась в путях, которые лишь начинаются с `$HOME` (`/home/bob2`).
- Тема коммита обрезалась по байтам и могла разорвать многобайтовый символ.
- При невалидном `settings.json` установщик оставлял файл пустым.

## [1.0.0] — 2026-09-01

### Добавлено
- Статуслайн: директория, git-ветка со статусом (staged/modified/untracked/конфликты, ahead/behind, stash, последний коммит), модель с размером контекста и уровнем effort, шкала заполнения контекста, лимиты использования (5-часовой, недельный, Sonnet) с временем сброса на русском.
- Установщик `install.sh`: копирует скрипт в `~/.claude/statusline.sh`, прописывает `statusLine` в `settings.json` с бэкапом; `git` — опциональная зависимость.
- Флаг `--version` / `-v` у скрипта.

[Unreleased]: https://github.com/foxtertime/claude-statusline/compare/v1.1.1...HEAD
[1.1.1]: https://github.com/foxtertime/claude-statusline/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/foxtertime/claude-statusline/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/foxtertime/claude-statusline/releases/tag/v1.0.0
