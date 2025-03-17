RETRY ?= 0
# STABILITY_TEST: Set to 1 to fail as soon as any of the RETRY fails rather
# than succeed if any of the RETRY succeed
STABILITY_TEST ?= 0
# KEEP_DB: Set to 1 to keep the test database process spawned for tests. This
# can help with faster re-runs of tests but might yield inconsistent results
KEEP_DB ?= 0
# CONTAINER_TEST: Set to 0 to exclude container tests needing a container
# runtime environment
CONTAINER_TEST ?= 1
# HELM_TEST: Set to 0 to exclude helm tests needing a kubernetes cluster
HELM_TEST ?= 1
# TESTS: Specify individual test files in a space separated lists. As the user
# most likely wants only the mentioned tests to be executed and no other
# checks this implicitly disables CHECKSTYLE
TESTS ?=
# EXTRA_PROVE_ARGS: Additional prove arguments to pass
EXTRA_PROVE_ARGS ?=
ifeq ($(TESTS),)
PROVE_ARGS ?= --trap -r ${EXTRA_PROVE_ARGS} t
else
CHECKSTYLE ?= 0
PROVE_ARGS ?= --trap ${EXTRA_PROVE_ARGS} $(TESTS)
endif
PROVE_LIB_ARGS ?= -l
TEST_PG_PATH ?= /dev/shm/tpg
# TIMEOUT_M: Timeout for one retry of tests in minutes
TIMEOUT_M ?= 60
ifeq ($(CI),)
SCALE_FACTOR ?= 1
else
SCALE_FACTOR ?= 2
endif
TIMEOUT_RETRIES ?= $$((${TIMEOUT_M} * ${SCALE_FACTOR} * (${RETRY} + 1) ))m
CRE ?= podman
# avoid localized error messages (that are matched against in certain cases)
LC_ALL = C.utf8
LANGUAGE =
LANG = C.utf8
mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(patsubst %/,%,$(dir $(mkfile_path)))
unstables := $(shell cat tools/unstable_tests.txt | tr '\n' :)
shellfiles := $$(file --mime-type script/* t/* container/worker/*.sh tools/* | sed -n 's/^\(.*\):.*text\/x-shellscript.*$$/\1/p')

# tests need these environment variables to be unset
OPENQA_BASEDIR =
OPENQA_CONFIG =
OPENQA_SCHEDULER_HOST =
OPENQA_WEB_SOCKETS_HOST =
OPENQA_SCHEDULER_STARVATION_PROTECTION_PRIORITY_OFFSET =

# change if os-autoinst project root is different from '../os-autoinst'
OS_AUTOINST_BASEDIR =

.PHONY: help
help:
	@echo Call one of the available targets:
	@sed -n 's/\(^[^.#[:space:]A-Z]*\):.*$$/\1/p' Makefile | uniq
	@echo See docs/Contributing.asciidoc for more details

.PHONY: install-generic
install-generic:
	./tools/generate-packed-assets
	for i in lib public script templates assets; do \
		mkdir -p "$(DESTDIR)"/usr/share/openqa/$$i ;\
		cp -a $$i/* "$(DESTDIR)"/usr/share/openqa/$$i ;\
	done
	for f in $(shell perl -Ilib -mOpenQA::Assets -e OpenQA::Assets::list); do \
		install -m 644 -D --target-directory="$(DESTDIR)/usr/share/openqa/$${f%/*}" "$$f";\
	done

	for i in db images testresults pool ; do \
		mkdir -p "$(DESTDIR)"/var/lib/openqa/$$i ;\
	done
# shared dirs between openQA web and workers + compatibility links
	for i in factory tests; do \
		mkdir -p "$(DESTDIR)"/var/lib/openqa/share/$$i ;\
		ln -sfn /var/lib/openqa/share/$$i "$(DESTDIR)"/var/lib/openqa/$$i ;\
	done
	for i in iso hdd repo other; do \
		mkdir -p "$(DESTDIR)"/var/lib/openqa/share/factory/$$i ;\
	done
	for i in script; do \
		ln -sfn /usr/share/openqa/$$i "$(DESTDIR)"/var/lib/openqa/$$i ;\
	done
#
	install -d -m 755 "$(DESTDIR)"/etc/apache2/vhosts.d
	for i in openqa-common.inc openqa.conf.template openqa-ssl.conf.template; do \
		install -m 644 etc/apache2/vhosts.d/$$i "$(DESTDIR)"/etc/apache2/vhosts.d ;\
	done

	install -d -m 755 "$(DESTDIR)"/etc/nginx/vhosts.d
	for i in openqa-locations.inc openqa-upstreams.inc openqa.conf.template; do \
		install -m 644 etc/nginx/vhosts.d/$$i "$(DESTDIR)"/etc/nginx/vhosts.d ;\
	done

	install -D -m 640 etc/openqa/client.conf "$(DESTDIR)"/etc/openqa/client.conf
	install -D -m 644 etc/openqa/workers.ini "$(DESTDIR)"/etc/openqa/workers.ini
	install -D -m 644 etc/openqa/openqa.ini "$(DESTDIR)"/etc/openqa/openqa.ini
	install -D -m 640 etc/openqa/database.ini "$(DESTDIR)"/etc/openqa/database.ini

	install -D -m 644 etc/logrotate.d/openqa "$(DESTDIR)"/etc/logrotate.d/openqa
#
	install -d -m 755 "$(DESTDIR)"/usr/lib/systemd/system
	install -d -m 755 "$(DESTDIR)"/usr/lib/systemd/system-generators
	install -d -m 755 "$(DESTDIR)"/usr/lib/tmpfiles.d
	eval "$$(perl -V:installvendorlib)" && sed -i -e "s^installvendorlib^$$installvendorlib^" systemd/openqa-minion-restart.path
	for i in systemd/*.{service,slice,target,timer,path}; do \
		install -m 644 $$i "$(DESTDIR)"/usr/lib/systemd/system ;\
	done
	ln -s openqa-worker-plain@.service "$(DESTDIR)"/usr/lib/systemd/system/openqa-worker@.service
	sed \
		-e 's_^\(ExecStart=/usr/share/openqa/script/worker\) \(--instance %i\)$$_\1 --no-cleanup \2_' \
		-e '/^$$/N;/\[Service\]/iConflicts=openqa-worker-plain@.service' \
		systemd/openqa-worker-plain@.service > "$(DESTDIR)"/usr/lib/systemd/system/openqa-worker-no-cleanup@.service
	sed \
		-e '/\[Service\]/aEnvironment=OPENQA_WORKER_TERMINATE_AFTER_JOBS_DONE=1' \
		-e '/ExecStart=/aExecReload=\/bin\/kill -HUP $$MAINPID' \
		-e 's/Restart=.*/Restart=always/' \
		-e '/^$$/N;/\[Service\]/iConflicts=openqa-worker-plain@.service' \
		systemd/openqa-worker-plain@.service > "$(DESTDIR)"/usr/lib/systemd/system/openqa-worker-auto-restart@.service
	install -m 755 systemd/systemd-openqa-generator "$(DESTDIR)"/usr/lib/systemd/system-generators
	install -m 644 systemd/tmpfiles-openqa.conf "$(DESTDIR)"/usr/lib/tmpfiles.d/openqa.conf
	install -m 644 systemd/tmpfiles-openqa-webui.conf "$(DESTDIR)"/usr/lib/tmpfiles.d/openqa-webui.conf
	install -d -m 755 "$(DESTDIR)"/usr/lib/systemd/system/openqa-gru.service.requires
	ln -s ../postgresql.service "$(DESTDIR)"/usr/lib/systemd/system/openqa-gru.service.requires/postgresql.service
	install -d -m 755 "$(DESTDIR)"/usr/lib/systemd/system/openqa-scheduler.service.requires
	ln -s ../postgresql.service "$(DESTDIR)"/usr/lib/systemd/system/openqa-scheduler.service.requires/postgresql.service
	install -d -m 755 "$(DESTDIR)"/usr/lib/systemd/system/openqa-websockets.service.requires
	ln -s ../postgresql.service "$(DESTDIR)"/usr/lib/systemd/system/openqa-websockets.service.requires/postgresql.service
#
# install openQA apparmor profile
	install -d -m 755 "$(DESTDIR)"/etc/apparmor.d
	install -m 644 profiles/apparmor.d/usr.share.openqa.script.openqa "$(DESTDIR)"/etc/apparmor.d
	install -m 644 profiles/apparmor.d/usr.share.openqa.script.worker "$(DESTDIR)"/etc/apparmor.d
	install -d -m 755 "$(DESTDIR)"/etc/apparmor.d/local
	install -m 644 profiles/apparmor.d/local/usr.share.openqa.script.openqa "$(DESTDIR)"/etc/apparmor.d/local
	install -m 644 profiles/apparmor.d/local/usr.share.openqa.script.worker "$(DESTDIR)"/etc/apparmor.d/local

	cp -Ra dbicdh "$(DESTDIR)"/usr/share/openqa/dbicdh

	install -d -m 755 "$(DESTDIR)"/usr/lib/sysusers.d/
	install    -m 644 usr/lib/sysusers.d/openQA-worker.conf "$(DESTDIR)"/usr/lib/sysusers.d/
	install    -m 644 usr/lib/sysusers.d/geekotest.conf "$(DESTDIR)"/usr/lib/sysusers.d/

# Additional services which have a strong dependency on SUSE/openSUSE and do not
# make sense for other distributions
.PHONY: install-opensuse
install-opensuse: install-generic
	for i in systemd/opensuse/*.{service,timer}; do \
		install -m 644 $$i "$(DESTDIR)"/usr/lib/systemd/system ;\
	done

# Match suse and opensuse
os := $(shell grep suse /etc/os-release)
.PHONY: install
ifeq ($(os),)
install: install-generic
else
install: install-opensuse
endif

# Ensure npm packages are installed and up-to-date (unless local-npm-registry is installed; in this case we can
# assume installing npm packages is taken care of separately, e.g. in builds on OBS)
node_modules: package-lock.json
	@which local-npm-registry >/dev/null 2>&1 || npm install --no-audit --no-fund
	@touch node_modules

.PHONY: test
ifeq ($(TRAVIS),true)
test: run-tests-within-container
else
ifeq ($(CHECKSTYLE),0)
checkstyle_tests =
else
checkstyle_tests = test-checkstyle-standalone
endif
test: $(checkstyle_tests) test-with-database
ifeq ($(CONTAINER_TEST),1)
ifeq ($(TESTS),)
test: test-containers-compose
endif
endif
ifeq ($(HELM_TEST),1)
ifeq ($(TESTS),)
test: test-helm-chart
endif
endif
endif

.PHONY: test-checkstyle
test-checkstyle: test-checkstyle-standalone test-tidy-compile

.PHONY: test-t
test-t: node_modules
	$(MAKE) test-with-database TIMEOUT_M=25 PROVE_ARGS="$$HARNESS t/*.t" GLOBIGNORE="t/*tidy*:t/*compile*:$(unstables)"

.PHONY: test-heavy
test-heavy: node_modules
	$(MAKE) test-with-database HEAVY=1 TIMEOUT_M=25 PROVE_ARGS="$$HARNESS $$(grep -l HEAVY=1 t/*.t | tr '\n' ' ')"

.PHONY: test-ui
test-ui: node_modules
	$(MAKE) test-with-database TIMEOUT_M=25 PROVE_ARGS="$$HARNESS t/ui/*.t" GLOBIGNORE="t/*tidy*:t/*compile*:$(unstables)"

.PHONY: test-api
test-api: node_modules
	$(MAKE) test-with-database TIMEOUT_M=20 PROVE_ARGS="$$HARNESS t/api/*.t" GLOBIGNORE="t/*tidy*:t/*compile*:$(unstables)"

# put unstable tests in tools/unstable_tests.txt and uncomment in circle CI config to handle unstables with retries
.PHONY: test-unstable
test-unstable: node_modules
	for f in $$(cat tools/unstable_tests.txt); do $(MAKE) test-with-database COVERDB_SUFFIX=$$(echo $${COVERDB_SUFFIX}_$$f | tr '/' '_') TIMEOUT_M=10 PROVE_ARGS="$$HARNESS $$f" RETRY=5 || exit; done

.PHONY: test-fullstack
test-fullstack: node_modules
	$(MAKE) test-with-database RETRY=200 TIMEOUT_M=10000 PROVE_ARGS="$$HARNESS t/full-stack.t t/33-developer_mode.t"

.PHONY: test-fullstack-unstable
test-fullstack-unstable: node_modules
	$(MAKE) test-with-database FULLSTACK=1 TIMEOUT_M=15 PROVE_ARGS="$$HARNESS t/05-scheduler-full.t" RETRY=5

# we have apparently-redundant -I args in PERL5OPT here because Docker
# only works with one and Fedora's build system only works with the other
.PHONY: test-with-database
test-with-database: node_modules setup-database
	$(MAKE) test-unit-and-integration TEST_PG="DBI:Pg:dbname=openqa_test;host=$(TEST_PG_PATH)"
	-[ $(KEEP_DB) = 1 ] || pg_ctl -D $(TEST_PG_PATH) stop

.PHONY: test-unit-and-integration
test-unit-and-integration: node_modules
	export GLOBIGNORE="$(GLOBIGNORE)";\
	export DEVEL_COVER_DB_FORMAT=JSON;\
	export PERL5OPT="$(COVEROPT)$(PERL5OPT) -It/lib -I$(PWD)/t/lib -I$(PWD)/external/os-autoinst-common/lib -MOpenQA::Test::PatchDeparse";\
	RETRY=${RETRY} HOOK=./tools/delete-coverdb-folder timeout -s SIGINT -k 5 -v ${TIMEOUT_RETRIES} tools/retry prove ${PROVE_LIB_ARGS} ${PROVE_ARGS}

.PHONY: setup-database
setup-database:
	test -d $(TEST_PG_PATH) && (pg_ctl -D $(TEST_PG_PATH) -s status >&/dev/null || pg_ctl -D $(TEST_PG_PATH) -s start) || ./t/test_postgresql $(TEST_PG_PATH)

# prepares running the tests within a container (eg. pulls os-autoinst) and then runs the tests considering
# the test matrix environment variables
# note: This is supposed to run within the container unlike `launch-container-to-run-tests-within`
#       which launches the container.
.PHONY: run-tests-within-container
run-tests-within-container:
	tools/run-tests-within-container

ifeq ($(COVERAGE),1)
COVERDB_SUFFIX ?=
# We use JSON::PP because there is a bug producing a (harmless) 'redefined'
# warning when using Devel::Cover and Cpanel::JSON::XS
# https://progress.opensuse.org/issues/90371
#
# CoverageWorkaround: We use a workaround with Syntax::Keyword::Try::Deparse
# because we would get warnings:
#     unexpected OP_CUSTOM (catch) at .../B/Deparse.pm line 1667.
# because Feature::Compat::Try uses OP_CUSTOM for perl < 5.40
# https://metacpan.org/pod/Feature::Compat::Try#COMPATIBILITY-NOTES
# https://rt.cpan.org/Transaction/Display.html?id=1992941
COVEROPT ?= -mJSON::PP -It/lib -MCoverageWorkaround -MDevel::Cover=-select_re,'^/lib',+ignore_re,lib/perlcritic/Perl/Critic/Policy|t/lib/CoverageWorkaround,-coverage,statement,-db,cover_db$(COVERDB_SUFFIX),
endif

.PHONY: coverage
coverage:
	export DEVEL_COVER_DB_FORMAT=JSON;\
	COVERAGE=1 cover ${COVER_OPTS} -test

COVER_REPORT_OPTS ?= -select_re '^(lib|script|t)/'

.PHONY: coverage-report-codecov
coverage-report-codecov:
	export DEVEL_COVER_DB_FORMAT=JSON;\
	cover $(COVER_REPORT_OPTS) -report codecovbash

.PHONY: coverage-codecov
coverage-codecov: coverage
	$(MAKE) coverage-report-codecov

.PHONY: coverage-report-html
coverage-report-html:
	cover $(COVER_REPORT_OPTS) -report html_minimal

.PHONY: coverage-html
coverage-html: coverage
	$(MAKE) coverage-report-html

public/favicon.ico: assets/images/logo.svg
	for w in 16 32 64 128; do \
		(cd assets/images/ && for i in *.svg; do \
			inkscape -e $${i%.svg}-$$w.png -w $$w $$i; \
		done); \
	done
	convert assets/images/logo-16.png assets/images/logo-32.png assets/images/logo-64.png assets/images/logo-128.png -background white -alpha remove public/favicon.ico
	rm assets/images/logo-128.png assets/images/logo-32.png assets/images/logo-64.png

# all additional checks not called by prove
.PHONY: test-checkstyle-standalone
test-checkstyle-standalone: test-shellcheck test-yaml test-critic test-shfmt
ifeq ($(CONTAINER_TEST),1)
test-checkstyle-standalone: test-check-containers
endif

.PHONY: test-critic
test-critic:
	tools/perlcritic lib

.PHONY: test-tidy-compile
test-tidy-compile:
	$(MAKE) test-unit-and-integration TIMEOUT_M=20 PROVE_ARGS="$$HARNESS t/*{tidy,compile}*.t" GLOBIGNORE="$(unstables)"

.PHONY: test-shellcheck
test-shellcheck:
	@which shellcheck >/dev/null 2>&1 || (echo "Command 'shellcheck' not found, can not execute shell script checks" && false)
	shellcheck -x $(shellfiles)

.PHONY: test-yaml
test-yaml:
	@which yamllint >/dev/null 2>&1 || (echo "Command 'yamllint' not found, can not execute YAML syntax checks" && false)
	@# Fall back to find if there is no git, e.g. in package builds
	yamllint --strict $$((git ls-files "*.yml" "*.yaml" 2>/dev/null || find -name '*.y*ml') | grep -v ^dbicdh)

.PHONY: test-shfmt
test-shfmt:
	@which shfmt >/dev/null 2>&1 || (echo "Command 'shfmt' not found, can not execute bash script syntax checks" && false)
	shfmt -d -i 4 -bn -ci -sr $(shellfiles)

.PHONY: test-check-containers
test-check-containers:
	tools/static_check_containers

.PHONY: tidy-js
tidy-js:
	tools/js-tidy

.PHONY: tidy-perl
tidy-perl:
	tools/tidyall -a

.PHONY: tidy
tidy: tidy-js tidy-perl

.PHONY: test-containers-compose
test-containers-compose:
	tools/test_containers_compose

.PHONY: test-helm-chart
test-helm-chart: test-helm-lint test-helm-install

.PHONY: test-helm-lint
test-helm-lint:
	tools/test_helm_chart lint

.PHONY: test-helm-install
test-helm-install:
	tools/test_helm_chart install

.PHONY: update-deps
update-deps:
	tools/update-deps --cpanfile cpanfile --specfile dist/rpm/openQA.spec

.PHONY: generate-docs
generate-docs:
	tools/generate-docs

.PHONY: serve-docs
serve-docs: generate-docs
	(cd docs/build/; python3 -m http.server)
