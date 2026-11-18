# Участие в разработке

## Окружение

Нужны `bash`, `jq`, `git`, `make`, [`shellcheck`](https://www.shellcheck.net) и [`shfmt`](https://github.com/mvdan/sh).

```bash
make hooks   # один раз после клонирования: проверка сообщений коммитов
make check   # shellcheck + shfmt + тесты; должно проходить перед каждым PR
make fmt     # отформатировать код
```

Тесты лежат в `tests/run.sh` и не требуют ничего, кроме bash, jq и git. Любое изменение поведения сопровождается тестом.

## Ветки — Gitflow

| Ветка | Назначение | Откуда | Куда вливается |
| --- | --- | --- | --- |
| `main` | Только выпущенные версии; каждый коммит слияния помечен тегом `vX.Y.Z` | — | — |
| `develop` | Интеграция следующего релиза | `main` | — |
| `feature/<имя>` | Новая функциональность, рефакторинг, документация | `develop` | `develop` |
| `release/<X.Y.Z>` | Подготовка релиза: версия, changelog, исправления | `develop` | `main` и `develop` |
| `hotfix/<X.Y.Z>` | Срочное исправление выпущенной версии | `main` | `main` и `develop` |

Все слияния — с `--no-ff`, чтобы ветка оставалась видна в истории. В `main` и `develop` напрямую не коммитим.

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

Версия хранится в одном месте — в переменной `VERSION` в `statusline.sh`. Тест проверяет, что она совпадает с последним разделом `CHANGELOG.md`.

## Changelog

Каждое заметное для пользователя изменение записывается в раздел `[Unreleased]` файла `CHANGELOG.md` в том же pull request. Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/).

## Выпуск релиза

```bash
git checkout develop && git pull
git checkout -b release/X.Y.Z

# 1. VERSION="X.Y.Z" в statusline.sh
# 2. в CHANGELOG.md: [Unreleased] → [X.Y.Z] — ГГГГ-ММ-ДД, обновить ссылки внизу
make check
git commit -am "chore(release): X.Y.Z"

git checkout main
git merge --no-ff release/X.Y.Z -m "Merge branch 'release/X.Y.Z'"
git tag -a vX.Y.Z -m "vX.Y.Z"

git checkout develop
git merge --no-ff release/X.Y.Z -m "Merge branch 'release/X.Y.Z' into develop"
git branch -d release/X.Y.Z

git push origin main develop
git push origin vX.Y.Z
```

Тег пушится отдельной командой, после веток. При выпуске 1.1.0 всё ушло одним `git push` — тем же, что впервые добавил workflow-файлы, — и `Release` не запустился ([#1](https://github.com/foxtertime/claude-statusline/issues/1)); точная причина не установлена, при выпуске 1.1.1 отдельный пуш тега сработал.

После пуша тега workflow `Release` проверяет, что тег совпадает с `VERSION`, и публикует релиз на GitHub с текстом из `CHANGELOG.md`. Если он не запустился, его можно запустить вручную для уже существующего тега:

```bash
gh workflow run release.yml -f tag=vX.Y.Z
```

Hotfix выпускается так же, но ветка `hotfix/X.Y.Z` создаётся от `main`.
