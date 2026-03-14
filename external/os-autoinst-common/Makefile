.PHONY: help
help:
	@echo Call one of the available targets:
	@sed -n 's/\(^[^.#[:space:]A-Z]*\):.*$$/\1/p' Makefile | uniq

.PHONY: update-deps
update-deps:
	tools/update-deps --cpanfile cpanfile

.PHONY: test-checkstyle
test-checkstyle:test-tidy test-critic test-yaml test-gitlint

.PHONY: test
test: test-checkstyle test-author test-t

.PHONY: test-tidy
test-tidy:
	tools/tidyall --all --check-only

.PHONY: test-critic
test-critic:
	tools/perlcritic --quiet .

.PHONY: test-yaml
test-yaml:
	yamllint --strict ./

.PHONY: test-gitlint
test-gitlint:
	@which gitlint >/dev/null 2>&1 || (echo "Command 'gitlint' not found, can not execute commit message checks. Install with 'python3-gitlint' (openSUSE) or 'pip install gitlint-core'" && false)
	@if git rev-parse --verify master >/dev/null 2>&1 && [ "$$(git rev-parse HEAD)" != "$$(git rev-parse master)" ]; then \
		gitlint --commits master..HEAD; \
	else \
		gitlint; \
	fi

.PHONY: test-author
test-author:
	prove -l -r xt/

.PHONY: test-t
test-t:
	prove -l -r t/
