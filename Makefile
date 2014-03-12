all:

install:
	for i in lib public script templates; do \
		mkdir -p "$(DESTDIR)"/usr/share/openqa/$$i ;\
		cp -a $$i/* "$(DESTDIR)"/usr/share/openqa/$$i ;\
	done
#
	for i in backlog factory/iso logs perl pool testresults logupload; do \
		mkdir -p "$(DESTDIR)"/var/lib/openqa/$$i ;\
	done
	for i in script; do \
		ln -sfn /usr/share/openqa/$$i "$(DESTDIR)"/var/lib/openqa/$$i ;\
	done
	ln -sfn /usr/lib/os-autoinst "$(DESTDIR)"/var/lib/openqa/perl/autoinst
#
	install -d -m 755 "$(DESTDIR)"/etc/apache2/{conf.d,vhosts.d}
	install -m 644 etc/apache2/conf.d/openqa.conf "$(DESTDIR)"/etc/apache2/conf.d
	for i in openqa-common.inc openqa.conf.template openqa-ssl.conf.template; do \
		install -m 644 etc/apache2/vhosts.d/$$i "$(DESTDIR)"/etc/apache2/vhosts.d ;\
	done

	install -D -m 640 etc/openqa/client.conf "$(DESTDIR)"/etc/openqa/client.conf
#
	install -d -m 755 "$(DESTDIR)"/usr/lib/systemd/{system,system-generators}
	install -m 644 systemd/openqa-worker@.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-worker.target "$(DESTDIR)"/usr/lib/systemd/system
	install -m 644 systemd/openqa-webui.service "$(DESTDIR)"/usr/lib/systemd/system
	install -m 755 systemd/systemd-openqa-generator "$(DESTDIR)"/usr/lib/systemd/system-generators
#
	install -D -m 640 /dev/null "$(DESTDIR)"/var/lib/openqa/db/db.sqlite
# install openQA apparmor profile
	install -d -m 755 "$(DESTDIR)"/etc/apparmor.d
	install -m 644 profiles/apparmor.d/usr.share.openqa.script.openqa "$(DESTDIR)"/etc/apparmor.d
	install -m 644 profiles/apparmor.d/usr.share.openqa.script.worker "$(DESTDIR)"/etc/apparmor.d

test:
	script/openqa test

.PHONY: all install test
