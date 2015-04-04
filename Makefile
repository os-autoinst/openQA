all:

install:
	for i in lib public script templates; do \
		mkdir -p "$(DESTDIR)"/usr/share/openqa/$$i ;\
		cp -a $$i/* "$(DESTDIR)"/usr/share/openqa/$$i ;\
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
	mkdir -p "$(DESTDIR)"/var/lib/openqa/share/factory/iso
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
	install -D -m 640 etc/openqa/openqa.ini "$(DESTDIR)"/etc/openqa/openqa.ini
	install -D -m 644 etc/openqa/database.ini "$(DESTDIR)"/etc/openqa/database.ini

	install -D -m 644 etc/logrotate.d/openqa "$(DESTDIR)"/etc/logrotate.d/openqa
#
	install -d -m 755 "$(DESTDIR)"/usr/lib/systemd/{system,system-generators}
	install -m 644 systemd/openqa-worker@.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-worker.target "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-webui.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-gru.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 755 systemd/systemd-openqa-generator "$(DESTDIR)"/usr/lib/systemd/system-generators
#
	install -D -m 640 /dev/null "$(DESTDIR)"/var/lib/openqa/db/db.sqlite
# install openQA apparmor profile
	install -d -m 755 "$(DESTDIR)"/etc/apparmor.d
	install -m 644 profiles/apparmor.d/usr.share.openqa.script.openqa "$(DESTDIR)"/etc/apparmor.d
	install -m 644 profiles/apparmor.d/usr.share.openqa.script.worker "$(DESTDIR)"/etc/apparmor.d

	cp -Ra dbicdh "$(DESTDIR)"/usr/share/openqa/dbicdh
test:
	OPENQA_CONFIG= prove -r

.PHONY: all install test
