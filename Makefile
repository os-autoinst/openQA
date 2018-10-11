PROVE_ARGS ?= -r -v
DOCKER_IMG ?= openqa:latest
mkfile_path := $(abspath $(lastword $(MAKEFILE_LIST)))
current_dir := $(patsubst %/,%,$(dir $(mkfile_path)))
docker_env_file := "$(current_dir)/docker.env"

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
	for i in tidy check_coverage generate-packed-assets generate-documentation generate-documentation-genapi.pl docker-tests; do \
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
	install -m 644 systemd/openqa-worker-cacheservice-minion@.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-scheduler.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-resource-allocator.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-setup-db.service "$(DESTDIR)"/usr/lib/systemd/system
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
ifneq ($(CHECKSTYLE),0)
	PERL5LIB=lib/perlcritic:$$PERL5LIB perlcritic --gentle lib
endif

.PHONY: test
ifeq ($(TRAVIS),true)
test: docker-tests
else
test: checkstyle
	OPENQA_CONFIG= prove ${PROVE_ARGS}
endif

.PHONY: docker-tests
docker-tests:
	script/docker-tests

# ignore tests and test related addons in coverage analysis
COVER_OPTS ?= -select_re "^/lib" -ignore_re '^t/.*' +ignore_re lib/perlcritic/Perl/Critic/Policy -coverage statement

.PHONY: coverage
coverage:
	cover ${COVER_OPTS} -test

COVER_REPORT_OPTS ?= -select_re ^lib/

.PHONY: travis-codecov
travis-codecov: coverage
	cover $(COVER_REPORT_OPTS) -report codecov

.PHONY: coverage-html
coverage-html: coverage
	cover $(COVER_REPORT_OPTS) -report html_basic

public/favicon.ico: assets/images/logo.svg
	for w in 16 32 64 128; do \
		inkscape -e assets/images/logo-$$w.png -w $$w assets/images/logo.svg ; \
	done
	convert assets/images/logo-16.png assets/images/logo-32.png assets/images/logo-64.png assets/images/logo-128.png -background white -alpha remove public/favicon.ico
	rm assets/images/logo-128.png assets/images/logo-32.png assets/images/logo-64.png

.PHONY: docker-test-build
docker-test-build:
	docker build --no-cache $(current_dir)/docker/openqa -t $(DOCKER_IMG)

.PHONY: docker.env
docker.env:
	env | grep -E 'FULLSTACK|UITEST|GH|TRAVIS|CPAN|DEBUG|ZYPPER' > $(docker_env_file)

.PHONY: docker-test-run
docker-test-run: docker.env
	docker run --env-file $(docker_env_file) -v $(current_dir):/opt/openqa -v /var/run/dbus:/var/run/dbus \
	   $(DOCKER_IMG) make travis-codecov
	rm $(docker_env_file)

.PHONY: docker-test-travis
docker-test-travis: docker.env
	docker run --env-file $(docker_env_file) -v $(current_dir):/opt/openqa -v /var/run/dbus:/var/run/dbus \
		-e TRAVIS=true $(DOCKER_IMG) make travis-codecov
	rm $(docker_env_file)

.PHONY: docker-test
docker-test: docker-test-build docker-test-run
	echo "Use docker-rm and docker-rmi to remove the container and image if necessary"
