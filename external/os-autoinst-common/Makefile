# PROVE: Test application for Perl tests
PROVE ?= tools/prove_wrapper
PROVE_JOBS ?= $(shell nproc 2>/dev/null || echo 1)
PROVE_JOBS_ARGS ?= -j$(PROVE_JOBS)

SH_FILES ?= $(shell file --mime-type $$(git ls-files) test/*.t | sed -n 's/^\(.*\):.*text\/x-shellscript.*$$/\1/p')
SH_SHELLCHECK_FILES ?= $(shell file --mime-type * | sed -n 's/^\(.*\):.*text\/x-shellscript.*$$/\1/p')

all: help

.PHONY: help
help: ## Display this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

.PHONY: update-deps
update-deps: ## Update dependencies
	tools/update-deps --cpanfile cpanfile

.PHONY: setup-hooks
setup-hooks: ## Install pre-commit git hooks
	pre-commit install --install-hooks -t commit-msg -t pre-commit

shfmt: ## Format shell scripts via shfmt
	shfmt -w ${SH_FILES}

test-shellcheck: ## Run shfmt and shellcheck tests
	@which shfmt >/dev/null 2>&1 || echo "Command 'shfmt' not found, can not execute shell script formating checks"
	shfmt -d ${SH_FILES}
	@which shellcheck >/dev/null 2>&1 || echo "Command 'shellcheck' not found, can not execute shell script checks"
	if [ -n "${SH_SHELLCHECK_FILES}" ]; then shellcheck -x ${SH_SHELLCHECK_FILES}; fi

.PHONY: test-checkstyle
test-checkstyle: test-tidy test-yaml test-gitlint test-shellcheck ## Run checkstyle checks

.PHONY: test
test: test-checkstyle test-author test-t ## Run all tests

.PHONY: test-tidy
test-tidy: ## Run tidyall checks
	tools/tidyall --all --check-only

.PHONY: test-yaml
test-yaml: ## Run yamllint checks
	yamllint --strict ./

.PHONY: test-gitlint
test-gitlint: ## Run gitlint checks
	@which gitlint >/dev/null 2>&1 || (echo "Command 'gitlint' not found, can not execute commit message checks. Install with 'python3-gitlint' (openSUSE) or 'pip install gitlint-core'" && false)
	@BASES=$$(for i in upstream/master upstream/main origin/master origin/main master main; do git rev-parse --verify $$i 2>/dev/null; done ||:); \
	BASE=$$(git merge-base --independent $$BASES | head -n 1); \
	gitlint --commits "$$BASE..HEAD"

.PHONY: test-author
test-author: ## Run author tests
	"${PROVE}" $(PROVE_JOBS_ARGS) -l -r xt/

.PHONY: test-t
test-t: ## Run unit tests
	"${PROVE}" $(PROVE_JOBS_ARGS) -l -r t/
