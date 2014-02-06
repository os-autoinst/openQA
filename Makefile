all:

install:
	DESTDIR="$(DESTDIR)" tools/install

test:
	rm -rf t/db; mkdir t/db
	echo .quit | sqlite3 -init tools/db.sql t/db/db.sqlite
	env OPENQA_DB=$(PWD)/t/db/db.sqlite prove
	rm -rf t/db

.PHONY: all install
