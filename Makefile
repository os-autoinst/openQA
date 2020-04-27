RETRY ?= 0
# STABILITY_TEST: Set to 1 to fail as soon as any of the RETRY fails rather
# than succeed if any of the RETRY succeed
STABILITY_TEST ?= 0
# KEEP_DB: Set to 1 to keep the test database process spawned for tests. This
# can help with faster re-runs of tests but might yield inconsistent results
KEEP_DB ?= 0
# TESTS: Specify individual test files in a space separated lists. As the user
# most likely wants only the mentioned tests to be executed and no other
# checks this implicitly disables CHECKSTYLE
TESTS ?=
ifeq ($(TESTS),)
PROVE_ARGS ?= $(HARNESS) -r -v
else
CHECKSTYLE ?= 0
PROVE_ARGS ?= $(HARNESS) -v $(TESTS)
endif
PROVE_LIB_ARGS ?= -l
DOCKER_IMG ?= openqa:latest
TEST_PG_PATH ?= /dev/shm/tpg
# TIMEOUT_M: Timeout for one retry of tests in minutes
TIMEOUT_M ?= 60
TIMEOUT_RETRIES ?= $$((${TIMEOUT_M} * (${RETRY} + 1) ))m
mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(patsubst %/,%,$(dir $(mkfile_path)))
docker_env_file := "$(current_dir)/docker.env"
unstables := $(cat .circleci/unstable_tests.txt | tr '\n' :)

# tests need these environment variables to be unset
OPENQA_BASEDIR =
OPENQA_CONFIG =

.PHONY: help
help:
	@echo Call one of the available targets:
	@sed -n 's/\(^[^.#[:space:]A-Z].*\):.*$$/\1/p' Makefile | uniq
	@echo See docs/Contributing.asciidoc for more details

.PHONY: install
install:
	./tools/generate-packed-assets
	for i in lib public script templates assets; do \
		mkdir -p "$(DESTDIR)"/usr/share/openqa/$$i ;\
		cp -a $$i/* "$(DESTDIR)"/usr/share/openqa/$$i ;\
	done

	for i in images testresults pool ; do \
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

	install -D -m 640 etc/openqa/client.conf "$(DESTDIR)"/etc/openqa/client.conf
	install -D -m 644 etc/openqa/workers.ini "$(DESTDIR)"/etc/openqa/workers.ini
	install -D -m 644 etc/openqa/openqa.ini "$(DESTDIR)"/etc/openqa/openqa.ini
	install -D -m 640 etc/openqa/database.ini "$(DESTDIR)"/etc/openqa/database.ini

	install -D -m 644 etc/logrotate.d/openqa "$(DESTDIR)"/etc/logrotate.d/openqa
#
	install -d -m 755 "$(DESTDIR)"/usr/lib/systemd/system
	install -d -m 755 "$(DESTDIR)"/usr/lib/systemd/system-generators
	install -d -m 755 "$(DESTDIR)"/usr/lib/tmpfiles.d
	install -m 644 systemd/openqa-worker@.service "$(DESTDIR)"/usr/lib/systemd/system
	sed -e 's_^\(ExecStart=/usr/share/openqa/script/worker\) \(--instance %i\)$$_\1 --no-cleanup \2_' \
		systemd/openqa-worker@.service \
		> "$(DESTDIR)"/usr/lib/systemd/system/openqa-worker-no-cleanup@.service
	sed -i '/Wants/aConflicts=openqa-worker@.service' \
		"$(DESTDIR)"/usr/lib/systemd/system/openqa-worker-no-cleanup@.service
	install -m 644 systemd/openqa-worker.target "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-webui.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-livehandler.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-gru.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-vde_switch.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-slirpvde.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-websockets.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-worker-cacheservice.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-worker-cacheservice-minion.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-scheduler.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-enqueue-audit-event-cleanup.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-enqueue-audit-event-cleanup.timer "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-enqueue-asset-cleanup.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-enqueue-asset-cleanup.timer "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-enqueue-result-cleanup.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-enqueue-result-cleanup.timer "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-enqueue-bug-cleanup.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-enqueue-bug-cleanup.timer "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-setup-db.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 755 systemd/systemd-openqa-generator "$(DESTDIR)"/usr/lib/systemd/system-generators
	install -m 644 systemd/tmpfiles-openqa.conf "$(DESTDIR)"/usr/lib/tmpfiles.d/openqa.conf
	install -m 644 systemd/tmpfiles-openqa-webui.conf "$(DESTDIR)"/usr/lib/tmpfiles.d/openqa-webui.conf
#
	install -D -m 640 /dev/null "$(DESTDIR)"/var/lib/openqa/db/db.sqlite
# install openQA apparmor profile
	install -d -m 755 "$(DESTDIR)"/etc/apparmor.d
	install -m 644 profiles/apparmor.d/usr.share.openqa.script.openqa "$(DESTDIR)"/etc/apparmor.d
	install -m 644 profiles/apparmor.d/usr.share.openqa.script.worker "$(DESTDIR)"/etc/apparmor.d
	install -d -m 755 "$(DESTDIR)"/etc/apparmor.d/local
	install -m 644 profiles/apparmor.d/local/usr.share.openqa.script.openqa "$(DESTDIR)"/etc/apparmor.d/local

	cp -Ra dbicdh "$(DESTDIR)"/usr/share/openqa/dbicdh


.PHONY: test
ifeq ($(TRAVIS),true)
test: run-tests-within-container
else
ifeq ($(CHECKSTYLE),0)
test: test-with-database
else
test: test-checkstyle-standalone test-with-database
endif
endif

.PHONY: test-checkstyle
test-checkstyle: test-checkstyle-standalone test-tidy-compile

.PHONY: test-t
test-t:
	$(MAKE) test-with-database TIMEOUT_M=25 PROVE_ARGS="$(PROVE_ARGS) t/*.t" GLOBIGNORE="t/*tidy*:t/*compile*:$(unstables)"

.PHONY: test-ui
test-ui:
	$(MAKE) test-with-database TIMEOUT_M=20 PROVE_ARGS="$(PROVE_ARGS) t/ui/*.t" GLOBIGNORE="t/*tidy*:t/*compile*:$(unstables)"

.PHONY: test-api
test-api:
	$(MAKE) test-with-database TIMEOUT_M=10 PROVE_ARGS="$(PROVE_ARGS) t/api/*.t" GLOBIGNORE="t/*tidy*:t/*compile*:$(unstables)"

# put unstable tests in unstable_tests.txt and uncomment in circle CI to handle unstables with retries
.PHONY: test-unstable
test-unstable:
	for f in $$(cat .circleci/unstable_tests.txt); do $(MAKE) test-with-database TIMEOUT_M=5 PROVE_ARGS="$(PROVE_ARGS) $f" RETRY=3 || break; done

.PHONY: test-fullstack
test-fullstack:
	$(MAKE) test-with-database FULLSTACK=1 TIMEOUT_M=20 PROVE_ARGS="$(PROVE_ARGS) t/full-stack.t" RETRY=3

.PHONY: test-scheduler
test-scheduler:
	$(MAKE) test-with-database SCHEDULER_FULLSTACK=1 SCALABILITY_TEST=1 TIMEOUT_M=5 PROVE_ARGS="$(PROVE_ARGS) t/05-scheduler-full.t t/43-scheduling-and-worker-scalability.t" RETRY=3

.PHONY: test-developer
test-developer:
	$(MAKE) test-with-database DEVELOPER_FULLSTACK=1 TIMEOUT_M=10 PROVE_ARGS="$(PROVE_ARGS) t/33-developer_mode.t" RETRY=3

.PHONY: test-with-database
test-with-database:
	test -d $(TEST_PG_PATH) && (pg_ctl -D $(TEST_PG_PATH) -s status >&/dev/null || pg_ctl -D $(TEST_PG_PATH) -s start) || ./t/test_postgresql $(TEST_PG_PATH)
	PERL5OPT="$(PERL5OPT) -I$(PWD)/t/lib -MOpenQA::Test::PatchDeparse" $(MAKE) test-unit-and-integration TEST_PG="DBI:Pg:dbname=openqa_test;host=$(TEST_PG_PATH)"
	-[ $(KEEP_DB) = 1 ] || pg_ctl -D $(TEST_PG_PATH) stop

.PHONY: test-unit-and-integration
test-unit-and-integration:
	export GLOBIGNORE="$(GLOBIGNORE)";\
	timeout -v ${TIMEOUT_RETRIES} tools/retry prove ${PROVE_LIB_ARGS} ${PROVE_ARGS}

# prepares running the tests within Docker (eg. pulls os-autoinst) and then runs the tests considering
# the test matrix environment variables
# note: This is supposed to run within the Docker container unlike `launch-docker-to-run-tests-within`
#       which launches the container.
.PHONY: run-tests-within-container
run-tests-within-container:
	tools/run-tests-within-container

# ignore tests and test related addons in coverage analysis
COVER_OPTS ?= -select_re '^/lib' -ignore_re '^t/.*' +ignore_re lib/perlcritic/Perl/Critic/Policy -coverage statement

comma := ,
space :=
space +=
.PHONY: print-cover-opts
print-cover-opt:
	  # this was used in writing .circleci/config.yml
	  @echo "$(subst $(space),$(comma),$(COVER_OPTS))"

.PHONY: coverage
coverage:
	cover ${COVER_OPTS} -test

COVER_REPORT_OPTS ?= -select_re ^lib/

.PHONY: coverage-codecov
coverage-codecov: coverage
	cover $(COVER_REPORT_OPTS) -report codecov

.PHONY: coverage-html
coverage-html: coverage
	cover $(COVER_REPORT_OPTS) -report html_basic

public/favicon.ico: assets/images/logo.svg
	for w in 16 32 64 128; do \
		(cd assets/images/ && for i in *.svg; do \
			inkscape -e $${i%.svg}-$$w.png -w $$w $$i; \
		done); \
	done
	convert assets/images/logo-16.png assets/images/logo-32.png assets/images/logo-64.png assets/images/logo-128.png -background white -alpha remove public/favicon.ico
	rm assets/images/logo-128.png assets/images/logo-32.png assets/images/logo-64.png

.PHONY: docker-test-build
docker-test-build:
	docker build --no-cache $(current_dir)/docker/openqa -t $(DOCKER_IMG)

.PHONY: docker.env
docker.env:
	env | grep -E 'CHECKSTYLE|FULLSTACK|UITEST|GH|TRAVIS|CPAN|DEBUG|ZYPPER' > $(docker_env_file)

.PHONY: launch-docker-to-run-tests-within
launch-docker-to-run-tests-within: docker.env
	docker run --env-file $(docker_env_file) -v $(current_dir):/opt/openqa \
	   $(DOCKER_IMG) make coverage-codecov
	rm $(docker_env_file)

.PHONY: prepare-and-launch-docker-to-run-tests-within
.NOTPARALLEL: prepare-and-launch-docker-to-run-tests-within
prepare-and-launch-docker-to-run-tests-within: docker-test-build launch-docker-to-run-tests-within
	echo "Use docker-rm and docker-rmi to remove the container and image if necessary"

# all additional checks not called by prove
.PHONY: test-checkstyle-standalone
test-checkstyle-standalone: test-shellcheck test-yaml test-critic

.PHONY: test-critic
test-critic:
	PERL5LIB=lib/perlcritic:$$PERL5LIB perlcritic lib

.PHONY: test-tidy-compile
test-tidy-compile:
	$(MAKE) test-unit-and-integration TIMEOUT_M=15 PROVE_ARGS="$(PROVE_ARGS) t/*{tidy,compile}*.t" GLOBIGNORE="$(unstables)"

.PHONY: test-shellcheck
test-shellcheck:
	@which shellcheck >/dev/null 2>&1 || echo "Command 'shellcheck' not found, can not execute shell script checks"
	shellcheck -x $$(file --mime-type script/* t/* | sed -n 's/^\(.*\):.*text\/x-shellscript.*$$/\1/p')

.PHONY: test-yaml
test-yaml:
	@which yamllint >/dev/null 2>&1 || echo "Command 'yamllint' not found, can not execute YAML syntax checks"
	@# Fall back to find if there is no git, e.g. in package builds
	yamllint --strict $$((git ls-files "*.yml" "*.yaml" 2>/dev/null || find -name '*.y*ml') | grep -v ^dbicdh)

.PHONY: update-deps
update-deps:
	tools/update-deps
