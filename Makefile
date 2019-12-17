PROVE_ARGS ?= -r -v
PROVE_LIB_ARGS ?= -l
DOCKER_IMG ?= openqa:latest
TEST_PG_PATH ?= /dev/shm/tpg
RETRY ?= 0
mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(patsubst %/,%,$(dir $(mkfile_path)))
docker_env_file := "$(current_dir)/docker.env"

.PHONY: help
help:
	@echo Call one of the available targets:
	@sed -n 's/\(^[^.#[:space:]A-Z].*\):.*$$/\1/p' Makefile | uniq
	@echo See docs/Contributing.asciidoc for more details

.PHONY: install
install:
	./script/generate-packed-assets
	for i in lib public script templates assets; do \
		mkdir -p "$(DESTDIR)"/usr/share/openqa/$$i ;\
		cp -a $$i/* "$(DESTDIR)"/usr/share/openqa/$$i ;\
	done

# we didn't actually want to install these...
	for i in tidy generate-packed-assets generate-documentation generate-documentation-genapi run-tests-within-container; do \
		rm "$(DESTDIR)"/usr/share/openqa/script/$$i ;\
	done
#
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
	install -m 644 systemd/openqa-setup-db.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 755 systemd/systemd-openqa-generator "$(DESTDIR)"/usr/lib/systemd/system-generators
	install -m 644 systemd/tmpfiles-openqa.conf "$(DESTDIR)"/usr/lib/tmpfiles.d/openqa.conf
#
	install -D -m 640 /dev/null "$(DESTDIR)"/var/lib/openqa/db/db.sqlite
# install openQA apparmor profile
	install -d -m 755 "$(DESTDIR)"/etc/apparmor.d
	install -m 644 profiles/apparmor.d/usr.share.openqa.script.openqa "$(DESTDIR)"/etc/apparmor.d
	install -m 644 profiles/apparmor.d/usr.share.openqa.script.worker "$(DESTDIR)"/etc/apparmor.d
	install -d -m 755 "$(DESTDIR)"/etc/apparmor.d/local
	install -m 644 profiles/apparmor.d/local/usr.share.openqa.script.openqa "$(DESTDIR)"/etc/apparmor.d/local

	cp -Ra dbicdh "$(DESTDIR)"/usr/share/openqa/dbicdh


.PHONY: checkstyle
checkstyle: test-shellcheck test-yaml
	PERL5LIB=lib/perlcritic:$$PERL5LIB perlcritic lib

.PHONY: test
ifeq ($(TRAVIS),true)
test: run-tests-within-container
else
ifeq ($(CHECKSTYLE),0)
test: test-with-database
else
test: checkstyle test-with-database
endif
endif

.PHONY: test-unit-and-integration
test-unit-and-integration:
ifeq ($(RETRY),0)
	export GLOBIGNORE="$(GLOBIGNORE)"; prove ${PROVE_LIB_ARGS} ${PROVE_ARGS}
else
	export GLOBIGNORE="$(GLOBIGNORE)";\
	n=0;\
	while :; do\
		[ $$n -lt "$(RETRY)" ] || exit 1;\
		[ $$n -eq 0 ] || echo Retrying...;\
		prove ${PROVE_LIB_ARGS} ${PROVE_ARGS} && break;\
		n=$$[$$n+1];\
	done
endif

.PHONY: test-with-database
test-with-database:
	test -d $(TEST_PG_PATH) && (pg_ctl -D $(TEST_PG_PATH) -s status >&/dev/null || pg_ctl -D $(TEST_PG_PATH) -s start) || ./t/test_postgresql $(TEST_PG_PATH)
	PERL5OPT="$(PERL5OPT) -I$(PWD)/t/lib -MOpenQA::Test::PatchDeparse" $(MAKE) test-unit-and-integration TEST_PG="DBI:Pg:dbname=openqa_test;host=$(TEST_PG_PATH)"
	-pg_ctl -D $(TEST_PG_PATH) stop

# prepares running the tests within Docker (eg. pulls os-autoinst) and then runs the tests considering
# the test matrix environment variables
# note: This is supposed to run within the Docker container unlike `launch-docker-to-run-tests-within`
#       which launches the container.
.PHONY: run-tests-within-container
run-tests-within-container:
	script/run-tests-within-container

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

.PHONY: test-shellcheck
test-shellcheck:
	@which shellcheck >/dev/null 2>&1 || echo "Command 'shellcheck' not found, can not execute shell script checks"
	shellcheck -x $$(file --mime-type script/* | sed -n 's/^\(.*\):.*text\/x-shellscript.*$$/\1/p')

.PHONY: test-yaml
test-yaml:
	@which yamllint >/dev/null 2>&1 || echo "Command 'yamllint' not found, can not execute YAML syntax checks"
	yamllint --strict $$(git ls-files "*.yml" "*.yaml" | grep -v ^dbicdh)
