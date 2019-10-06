PROVE_ARGS ?= -r -v
PROVE_LIB_ARGS ?= -l
DOCKER_IMG ?= openqa:latest
TEST_PG_PATH ?= /dev/shm/tpg
mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(patsubst %/,%,$(dir $(mkfile_path)))

.PHONY: all
all:

.PHONY: install
install:
	./script/generate-packed-assets
	for i in lib public script templates assets; do \
		mkdir -p "$(DESTDIR)"/usr/share/openqa/$$i ;\
		cp -a $$i/* "$(DESTDIR)"/usr/share/openqa/$$i ;\
	done

# we didn't actually want to install these...
	for i in tidy check_coverage generate-packed-assets generate-documentation generate-documentation-genapi; do \
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

	cp -Ra dbicdh "$(DESTDIR)"/usr/share/openqa/dbicdh


.PHONY: checkstyle
checkstyle: test-shellcheck
ifneq ($(CHECKSTYLE),0)
	PERL5LIB=lib/perlcritic:$$PERL5LIB perlcritic lib
endif

test-with-db%: 
	@$(MAKE) $(subst test-with-db,test-with-database,$@)

test-with-database%:
	test -d $(TEST_PG_PATH) && (pg_ctl -D $(TEST_PG_PATH) -s status >&/dev/null || pg_ctl -D $(TEST_PG_PATH) -s start) || ./t/test_postgresql $(TEST_PG_PATH)
	$(MAKE) $(subst -with-database,,$@) TEST_PG="DBI:Pg:dbname=openqa_test;host=$(TEST_PG_PATH)"
	-pg_ctl -D $(TEST_PG_PATH) stop

test%:
	@GLOBIGNORE=$(shell paste -sd: t/unstable_tests.txt); \
	[ $@ == test-with-d* ] || case $@ in \
		test-t*) prove -l -v t/$(subst test-t,,$@)*.t;; \
		test-api*) prove -l -v t/api/$(subst test-api,,$@)*.t;; \
		test-ui*) prove -l -v t/ui/$(subst test-ui,,$@)*.t;; \
		test-dev*) DEVELOPER_FULLSTACK=1 prove -l -v t/33-developer_mode.t;; \
		test-sched*) SCHEDULER_FULLSTACK=1 prove -l -v t/05-scheduler-full.t;; \
		test-full*) FULLSTACK=1 prove -l -v t/full-stack.t;; \
		test-unstable*) for f in $(shell cat t/unstable_tests.txt); do \
		                  prove -l -v $$f || prove -l -v $$f || prove -l -v $$f; \
		                done ;; \
		test) prove -l -v -r;; \
	    *) ( echo Unkown target $@; exit 1 )>&2 ;; \
	esac ;

# ignore tests and test related addons in coverage analysis
COVER_OPTS ?= -select_re '^/lib' -ignore_re '^t/.*' +ignore_re lib/perlcritic/Perl/Critic/Policy -coverage statement

coverage-%:
	@[ $@ == coverage-merge-db ] || \
	  [ $@ == coverage-report* ] || \
	  cover $(COVER_OPTS) -test -make 'make $(subst coverage-,test-,$@) #' cover_db_$(subst test-cover-,,$@)

.PHONY: coverage
coverage:
	cover ${COVER_OPTS} -test

.PHONY: coverage-merge-db
coverage-merge-db:
	cover ${COVER_OPTS} -write cover_db cover_db_*

COVER_REPORT_OPTS ?= -select_re ^lib/

.PHONY: coverage-report-codecov
coverage-report-codecov:
	cover $(COVER_REPORT_OPTS) -report codecov cover_db

.PHONY: coverage-report-html
coverage-report-html:
	cover $(COVER_REPORT_OPTS) -report html_basic cover_db

public/favicon.ico: assets/images/logo.svg
	for w in 16 32 64 128; do \
		inkscape -e assets/images/logo-$$w.png -w $$w assets/images/logo.svg ; \
	done
	convert assets/images/logo-16.png assets/images/logo-32.png assets/images/logo-64.png assets/images/logo-128.png -background white -alpha remove public/favicon.ico
	rm assets/images/logo-128.png assets/images/logo-32.png assets/images/logo-64.png

.PHONY: test-shellcheck
test-shellcheck:
	@which shellcheck >/dev/null 2>&1 || echo "Command 'shellcheck' not found, can not execute shell script checks"
	shellcheck -x $$(file --mime-type script/* | sed -n 's/^\(.*\):.*text\/x-shellscript.*$$/\1/p')
