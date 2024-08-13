.PHONY: help
help:
	@echo Call one of the available targets:
	@sed -n 's/\(^[^.#[:space:]A-Z]*\):.*$$/\1/p' Makefile | uniq

.PHONY: update-deps
update-deps:
	tools/update-deps --cpanfile cpanfile

.PHONY: test
test: test-tidy test-critic test-yaml test-author test-t

.PHONY: test-tidy
test-tidy:
	tools/tidyall --all --check-only

.PHONY: test-critic
test-critic:
	tools/perlcritic --quiet .

.PHONY: test-yaml
test-yaml:
	yamllint --strict ./

.PHONY: test-author
test-author:
	prove -l -r xt/

.PHONY: test-t
test-t:
	prove -l -r t/
