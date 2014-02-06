all:

install:
	DESTDIR="$(DESTDIR)" tools/install

test:
	rm -rf t/openqa; mkdir -p t/openqa/{db,factory/iso}
	echo .quit | sqlite3 -init tools/db.sql t/openqa/db/db.sqlite
	env OPENQA_BASEDIR=$(PWD)/t prove
	rm -rf t/openqa

.PHONY: all install
