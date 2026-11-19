SHELL_FILES := src/statusline.sh src/install.sh tests/run.sh .githooks/commit-msg

.DEFAULT_GOAL := help
.PHONY: help check lint fmt fmt-check test install uninstall hooks

help: ## Показать список целей
	@awk -F ':.*## ' '/^[a-z-]+:.*## /{printf "  %-10s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check: lint fmt-check test ## Всё, что проверяет CI

lint: ## shellcheck
	shellcheck $(SHELL_FILES)

fmt: ## Отформатировать shfmt
	shfmt -w $(SHELL_FILES)

fmt-check: ## Проверить форматирование
	shfmt -d $(SHELL_FILES)

test: ## Запустить тесты
	./tests/run.sh

install: ## Установить статуслайн в Claude Code
	src/install.sh

uninstall: ## Удалить статуслайн
	src/install.sh --uninstall

hooks: ## Включить git-хук проверки сообщений коммитов
	git config core.hooksPath .githooks
