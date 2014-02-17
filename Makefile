all:

install:
	DESTDIR="$(DESTDIR)" tools/install

test:
	script/openqa test

.PHONY: all install test
