all:

install:
	DESTDIR="$(DESTDIR)" tools/install

.PHONY: all install
