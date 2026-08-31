# Changelog

Формат — [Keep a Changelog](https://keepachangelog.com/ru/1.1.0/), версии — [SemVer](https://semver.org/lang/ru/).

## [1.0.0] — 2026-09-01

### Добавлено
- Статуслайн: директория, git-ветка со статусом (staged/modified/untracked/конфликты, ahead/behind, stash, последний коммит), модель с размером контекста и уровнем effort, шкала заполнения контекста, лимиты использования (5-часовой, недельный, Sonnet) с временем сброса на русском.
- Установщик `install.sh`: копирует скрипт в `~/.claude/statusline.sh`, прописывает `statusLine` в `settings.json` с бэкапом; `git` — опциональная зависимость.
- Флаг `--version` / `-v` у скрипта.
