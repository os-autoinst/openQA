all:

install:
	DESTDIR="$(DESTDIR)" tools/install

test:
	$(MAKE) -C t test

.PHONY: all install
