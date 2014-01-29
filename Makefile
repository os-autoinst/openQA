all:

install:
	DESTDIR="$(DESTDIR)" tools/install

test:
	prove

.PHONY: all install
