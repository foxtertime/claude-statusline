# Участие в разработке

## Окружение

Нужны `bash`, `jq`, `git`, `make`, [`shellcheck`](https://www.shellcheck.net) и [`shfmt`](https://github.com/mvdan/sh).

```bash
make hooks   # один раз после клонирования: проверка сообщений коммитов
make check   # shellcheck + shfmt + тесты; должно проходить перед каждым PR
make fmt     # отформатировать код
```

Тесты лежат в `tests/run.sh` и не требуют ничего, кроме bash, jq и git. Любое изменение поведения сопровождается тестом.

## Структура

| Путь | Что там |
| --- | --- |
| `src/statusline.sh` | Сам статуслайн — единственный файл, который ставится пользователю |
| `src/install.sh` | Установщик: установка, настройки, `--check`, `--uninstall` |
| `tests/run.sh` | Тесты обоих скриптов |
| `.github/workflows/` | CI (`ci.yml`) и выпуск релиза (`release.yml`) |
| `.githooks/commit-msg` | Проверка Conventional Commits |

В релиз скрипты прикладываются без каталога: `statusline.sh`, `install.sh`, `SHA256SUMS`.

## Ветки — Gitflow

| Ветка | Назначение | Откуда | Куда вливается |
| --- | --- | --- | --- |
| `main` | Только выпущенные версии; каждый коммит слияния помечен тегом `vX.Y.Z` | — | — |
| `develop` | Интеграция следующего релиза | `main` | — |
| `feature/<имя>` | Новая функциональность, рефакторинг, документация | `develop` | `develop` |
| `release/<X.Y.Z>` | Подготовка релиза: версия, changelog, исправления | `develop` | `main` и `develop` |
| `hotfix/<X.Y.Z>` | Срочное исправление выпущенной версии | `main` | `main` и `develop` |

В `main` и `develop` напрямую не коммитим и не пушим.

## Задачи и pull request'ы

Любая работа начинается с issue и попадает в `develop` или `main` только через pull request — это относится и к feature-, и к release-, и к hotfix-веткам.

Для ошибок и предложений есть шаблоны (`.github/ISSUE_TEMPLATE/`): шаблон ошибки просит входной JSON, ширину, опции, ОС, версию bash и вывод `install.sh --check`, шаблон предложения добавляет стандартный чек-лист. Для мелких задач и chore можно открыть пустую issue.

```bash
gh issue create --assignee @me               # или найти существующую: gh issue list,
                                             # и взять её: gh issue edit <номер> --add-assignee @me
git checkout develop && git pull
git checkout -b feature/<номер>-<имя>
# ... изменения, make check, коммиты ...
git push -u origin feature/<номер>-<имя>
gh pr create --base develop --assignee @me   # в описании: Closes #<номер>
gh pr checks --watch                         # дождаться CI, включая macOS
gh pr merge --merge --delete-branch
gh issue close <номер> --comment "Сделано в #<номер PR>"
```

- Сливаем только при зелёном CI и только merge-коммитом (`--merge`), без squash и rebase: ветка должна оставаться видна в истории.
- Один pull request — одна issue.
- Issue, взятая в работу, и открытый pull request назначаются на себя (`--assignee @me`).
- Если в issue есть чек-лист (`- [ ]`), каждый пункт отмечается, как только сделан (`gh issue edit <номер> --body-file …`). К слиянию pull request'а все пункты, которые он закрывает, должны быть отмечены.
- `Closes #N` закрывает issue автоматически лишь при слиянии в `main`, поэтому после слияния в `develop` issue закрывается вручную.

## Коммиты — Conventional Commits

```
<type>(<scope>): <описание>

<тело: что изменилось и почему>
```

- **type**: `feat`, `fix`, `docs`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`
- **scope** (необязателен): `statusline`, `install`, `release`
- заголовок — на английском, в повелительном наклонении, до 72 символов, без точки в конце
- несовместимое изменение — `!` после типа и абзац `BREAKING CHANGE:` в теле

Формат проверяется хуком `.githooks/commit-msg` и в CI для каждого pull request.

## Версии — SemVer

Публичный интерфейс проекта — вывод статуслайна, флаги `statusline.sh` и `install.sh`, список зависимостей.

- **MAJOR** — несовместимые изменения: удалён флаг, появилась новая обязательная зависимость, изменился формат установки
- **MINOR** — новая функциональность (`feat`)
- **PATCH** — только исправления (`fix`, `perf`)

Версия хранится в одном месте — в переменной `VERSION` в `src/statusline.sh`. Тест проверяет, что она совпадает с последним разделом `CHANGELOG.md`.

## Changelog

Каждое заметное для пользователя изменение записывается в раздел `[Unreleased]` файла `CHANGELOG.md` в том же pull request. Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/).

## Выпуск релиза

```bash
git checkout develop && git pull
git checkout -b release/X.Y.Z

# 1. VERSION="X.Y.Z" в src/statusline.sh
# 2. в CHANGELOG.md: [Unreleased] → [X.Y.Z] — ГГГГ-ММ-ДД, обновить ссылки внизу
make check
git commit -am "chore(release): X.Y.Z"
git push -u origin release/X.Y.Z

# 3. PR в main; ветку пока не удаляем
gh pr create --base main --title "chore(release): X.Y.Z"
gh pr checks --watch
gh pr merge --merge

# 4. тег на merge-коммит в main
git checkout main && git pull
git tag -a vX.Y.Z -m "vX.Y.Z"
git push origin vX.Y.Z

# 5. PR той же ветки в develop
gh pr create --base develop --head release/X.Y.Z --title "chore(release): merge X.Y.Z back into develop"
gh pr checks --watch
gh pr merge --merge --delete-branch
```

Тег пушится отдельной командой, когда `main` уже на GitHub. При выпуске 1.1.0 ветки и тег ушли одним `git push` — тем же, что впервые добавил workflow-файлы, — и `Release` не запустился ([#1](https://github.com/foxtertime/claude-statusline/issues/1)); точная причина не установлена.

После пуша тега workflow `Release` проверяет, что тег совпадает с `VERSION`, публикует релиз на GitHub с текстом из `CHANGELOG.md` и прикладывает к нему `statusline.sh`, `install.sh` и `SHA256SUMS` — с них работает установка без клонирования. Если он не запустился, его можно запустить вручную для уже существующего тега:

```bash
gh workflow run release.yml -f tag=vX.Y.Z
```

Hotfix выпускается так же — двумя pull request'ами, — но ветка `hotfix/X.Y.Z` создаётся от `main`.
