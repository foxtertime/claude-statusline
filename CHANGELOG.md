# Changelog

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии — [SemVer](https://semver.org/lang/ru/).

## [Unreleased]

### Изменено
- Установщик сохраняет исходный `settings.json` в `settings.json.orig` при первом изменении и больше его не перезаписывает; `settings.json.bak`, как и раньше, — версия перед последним запуском ([#47](https://github.com/foxtertime/claude-statusline/issues/47)).

### Исправлено
- Установщик больше не заменяет `settings.json`, который является символической ссылкой (например, из менеджера dotfiles), обычным файлом и сохраняет его права доступа ([#46](https://github.com/foxtertime/claude-statusline/issues/46)).
- `install.sh --padding 00` и `--refresh 00` теперь считаются нулём и убирают ключ, как `0`; ведущие нули в числах отбрасываются ([#49](https://github.com/foxtertime/claude-statusline/issues/49)).
- `--demo` больше не показывает `?` и пустые сегменты, когда в `HOME` есть кавычка или обратная косая черта ([#53](https://github.com/foxtertime/claude-statusline/issues/53)).
- Имена в `STATUSLINE_LAYOUT` больше не раскрываются как шаблоны файлов: `*` или `?` в раскладке не зависят от содержимого текущего каталога ([#52](https://github.com/foxtertime/claude-statusline/issues/52)).
- Огромные числа во входе (`1e300`) больше не завершают скрипт с ошибкой и обрезанным выводом: значения больше 10¹⁵ по модулю отбрасываются ([#45](https://github.com/foxtertime/claude-statusline/issues/45)).
- Поле входа неожиданного типа (например, строка вместо объекта `model` или `context_window`) больше не стирает весь статуслайн: пропадает только оно само ([#44](https://github.com/foxtertime/claude-statusline/issues/44)).
- Суммы `rate_limits.spend_limit` (`used_usd`, `limit_usd`) округляются до центов (`$0.30` вместо `$0.30000000000000004`), а не-числа отбрасываются: управляющие последовательности из этих полей больше не попадают в терминал ([#43](https://github.com/foxtertime/claude-statusline/issues/43)).

## [1.4.0] — 2026-11-19

### Добавлено
- Текущая директория в строке 1 — кликабельная ссылка `file://` на полный путь: терминалы с поддержкой OSC 8 открывают её в файловом менеджере или редакторе. В ссылке есть имя хоста, чтобы по SSH терминал не открыл одноимённую папку на своей машине. Отключается вместе с остальными ссылками: `STATUSLINE_HIDE=links` или `NO_COLOR` ([#71](https://github.com/foxtertime/claude-statusline/issues/71)).

### Изменено
- `statusline.sh` и `install.sh` перенесены в каталог `src/`. В копии репозитория установка и обновление теперь `make install` (или `src/install.sh`) вместо `./install.sh`. Установленный скрипт, `settings.json` и установка без клонирования не меняются: файлы в релизе по-прежнему называются `statusline.sh`, `install.sh` и `SHA256SUMS` ([#69](https://github.com/foxtertime/claude-statusline/issues/69)).

### Исправлено
- `install.sh --set` отклонял `STATUSLINE_LAYOUT` и `STATUSLINE_COLOR_CRIT`, а `--check` называл их неизвестными; имя опции с пробелом больше не принимается ([#40](https://github.com/foxtertime/claude-statusline/issues/40)).
- На узком терминале длинное имя ветки снова отрастало, когда из строки 1 убирались worktree и pull request, и строка не помещалась ([#41](https://github.com/foxtertime/claude-statusline/issues/41)).
- Скачанный установщик ставил любой `statusline.sh`, лежащий рядом, без сверки с `SHA256SUMS`; теперь соседний файл берётся только в копии репозитория. Запуск установщика из каталога настроек больше не переписывает `settings.json` перед ошибкой ([#42](https://github.com/foxtertime/claude-statusline/issues/42)).

## [1.3.0] — 2026-11-19


### Добавлено
- Установщик: установка без клонирования из релиза с проверкой `SHA256SUMS`; `--set`, `--unset`, `--refresh` и `--padding` для настроек; `--check` для диагностики. `STATUSLINE_PADDING` выставляется автоматически по `statusLine.padding`; `--uninstall` убирает и опции ([#23](https://github.com/foxtertime/claude-statusline/issues/23)).
- `STATUSLINE_LAYOUT`: порядок сегментов строки 2, перенос части сегментов на отдельную строку через `/` и однострочный режим `compact` ([#20](https://github.com/foxtertime/claude-statusline/issues/20)).
- `STATUSLINE_PADDING` — передаёт скрипту `statusLine.padding`, чтобы строки с отступом не обрезались ([#21](https://github.com/foxtertime/claude-statusline/issues/21)).
- Темы и цвета: `STATUSLINE_THEME=light` для светлого фона и `STATUSLINE_COLOR_<РОЛЬ>` для отдельных ролей; `STATUSLINE_ASCII=1` — режим без псевдографики ([#26](https://github.com/foxtertime/claude-statusline/issues/26)).
- Флаг `--demo`: статуслайн на встроенном примере данных со всеми сегментами — чтобы увидеть действие настроек сразу ([#24](https://github.com/foxtertime/claude-statusline/issues/24)).

### Изменено
- Подгонка под ширину: запас подтверждён замером (Claude Code показывает `COLUMNS − 4 − 2 × padding` колонок); иероглифы и эмодзи считаются за две колонки; строки лимитов теперь тоже ужимаются; строка 1 и сегмент модели получили дополнительные ступени сокращения ([#21](https://github.com/foxtertime/claude-statusline/issues/21)).
- В русском режиме переведены все подписи: `Контекст`, `Кэш`, `Сейчас`, `Неделя`, `Расход`, `[чисто]`, состояния ревью и другие ([#26](https://github.com/foxtertime/claude-statusline/issues/26)).
- Время сброса лимитов и остывания кэша форматируется без запуска `date` на bash 4.2+: отрисовка с тремя строками лимитов и кэшем ускорилась примерно с 39 до 10 мс. На bash 3.2 (macOS) по-прежнему используется `date` ([#25](https://github.com/foxtertime/claude-statusline/issues/25)).

### Исправлено
- На узком терминале путь без `/` (например, `?`, когда директория неизвестна) превращался в одно многоточие.
- Управляющие символы в теме коммита и в пути больше не попадают в терминал: раньше коммит с escape-последовательностями мог очистить экран или сменить заголовок окна ([#34](https://github.com/foxtertime/claude-statusline/issues/34)).
- Подгонка под ширину замедляла каждую отрисовку до 55–120 мс (Claude Code всегда передаёт `COLUMNS`); теперь 12–15 мс ([#31](https://github.com/foxtertime/claude-statusline/issues/31)).

## [1.2.0] — 2026-11-19

### Добавлено
- Имя ветки — кликабельная ссылка на ветку на GitHub или на репозиторий на другом хостинге ([#11](https://github.com/foxtertime/claude-statusline/issues/11)).
- `STATUSLINE_GIT_CACHE` — кэш состояния git на заданное число секунд для очень больших репозиториев; по умолчанию выключен ([#10](https://github.com/foxtertime/claude-statusline/issues/10)).
- Индикаторы режимов: `fast`, имя агента, режим vim, имя сессии и имя git worktree ([#9](https://github.com/foxtertime/claude-statusline/issues/9)).
- Состояние кэша промпта в строке 2: доля чтений из кэша и время, когда он остынет ([#8](https://github.com/foxtertime/claude-statusline/issues/8)).
- `STATUSLINE_RESET=relative` — время до сброса лимита («через 2 ч 10 мин») вместо времени на часах ([#7](https://github.com/foxtertime/claude-statusline/issues/7)).
- Сегмент сессии в строке 2: оценка стоимости, длительность, добавленные и удалённые строки ([#6](https://github.com/foxtertime/claude-statusline/issues/6)).
- Открытый pull request текущей ветки рядом с веткой: номер, состояние ревью и ссылка; merge request GitLab — как `!123` ([#5](https://github.com/foxtertime/claude-statusline/issues/5)).
- Строки подстраиваются под ширину терминала (`COLUMNS`): строка 1 по шагам теряет тему коммита, начало пути и хвост имени ветки, строка 2 — сегменты с конца ([#3](https://github.com/foxtertime/claude-statusline/issues/3)).
- Настройка переменными окружения: `STATUSLINE_LANG` (язык дат), `STATUSLINE_BAR_WIDTH`, `STATUSLINE_WARN` / `STATUSLINE_CRIT` (пороги цвета) и `STATUSLINE_HIDE` (скрытие сегментов) ([#4](https://github.com/foxtertime/claude-statusline/issues/4)).

### Исправлено
- Управляющие символы в текстовых полях (имя модели, сессии, агента) больше не ломают строки.

### Изменено
- **Язык дат теперь выбирается по локали**: русский при русской локали, иначе английский. Если локаль системы не русская, а даты нужны на русском, задайте `STATUSLINE_LANG=ru` ([#12](https://github.com/foxtertime/claude-statusline/issues/12)).

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

[Unreleased]: https://github.com/foxtertime/claude-statusline/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/foxtertime/claude-statusline/compare/v1.3.0...v1.4.0
[1.3.0]: https://github.com/foxtertime/claude-statusline/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/foxtertime/claude-statusline/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/foxtertime/claude-statusline/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/foxtertime/claude-statusline/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/foxtertime/claude-statusline/releases/tag/v1.0.0
