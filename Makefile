COVERAGE_THRESHOLD ?= 64.6
PROVE_ARGS ?= -r

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
	for i in tidy check_coverage generate-packed-assets; do \
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
	install -d -m 755 "$(DESTDIR)"/usr/lib/systemd/{system,system-generators}
	install -d -m 755 "$(DESTDIR)"/usr/lib/tmpfiles.d
	install -m 644 systemd/openqa-worker@.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-worker.target "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-webui.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-gru.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-vde_switch.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-slirpvde.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-websockets.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-scheduler.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 755 systemd/systemd-openqa-generator "$(DESTDIR)"/usr/lib/systemd/system-generators
	install -m 644 systemd/tmpfiles-openqa.conf "$(DESTDIR)"/usr/lib/tmpfiles.d/openqa.conf
	install -D -m 644 etc/dbus-1/system.d/org.opensuse.openqa.conf "$(DESTDIR)"/etc/dbus-1/system.d/org.opensuse.openqa.conf
#
	install -D -m 640 /dev/null "$(DESTDIR)"/var/lib/openqa/db/db.sqlite
# install openQA apparmor profile
	install -d -m 755 "$(DESTDIR)"/etc/apparmor.d
	install -m 644 profiles/apparmor.d/usr.share.openqa.script.openqa "$(DESTDIR)"/etc/apparmor.d
	install -m 644 profiles/apparmor.d/usr.share.openqa.script.worker "$(DESTDIR)"/etc/apparmor.d

	cp -Ra dbicdh "$(DESTDIR)"/usr/share/openqa/dbicdh


.PHONY: checkstyle
checkstyle:
	PERL5LIB=lib/perlcritic:$$PERL5LIB perlcritic --gentle --include Perl::Critic::Policy::HashKeyQuote lib

.PHONY: test
test: checkstyle
	OPENQA_CONFIG= prove ${PROVE_ARGS}

# ignore tests and test related addons in coverage analysis
COVER_OPTS ?= -ignore_re "t/.*" -ignore lib/perlcritic/Perl/Critic/Policy/HashKeyQuotes.pm
cover_db/:
	MOJO_LOG_LEVEL=debug OPENQA_LOGFILE=/tmp/openqa-debug.log cover ${COVER_OPTS} -test -coverage default,-pod

.PHONY: coverage-test
coverage-test: cover_db/

.PHONY: coverage
coverage: coverage-html

.PHONY: coverage-coveralls
coverage-coveralls: cover_db/
	cover ${COVER_OPTS} -report coveralls

cover_db/coverage.html: cover_db/
	cover ${COVER_OPTS} -report html

.PHONY: coverage-html
coverage-html: cover_db/coverage.html

.PHONY: coverage-check
coverage-check: cover_db/coverage.html
	./script/check_coverage ${COVERAGE_THRESHOLD}
