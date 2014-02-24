all:

install:
	DESTDIR="$(DESTDIR)" script/install

test:
	script/openqa test

.PHONY: all install test
