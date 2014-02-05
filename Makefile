all:

install:
	DESTDIR="$(DESTDIR)" tools/install

test:
	rm /var/lib/openqa/db/db.sqlite
	echo .quit | sqlite3 -init tools/db.sql /var/lib/openqa/db/db.sqlite
	prove

.PHONY: all install
