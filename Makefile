all:

install:
	DESTDIR="$(DESTDIR)" tools/install

test:
	rm -rf t/openqa; mkdir -p t/openqa/{db,factory/iso}
	env OPENQA_BASEDIR=$(PWD)/t tools/initdb
	env OPENQA_BASEDIR=$(PWD)/t prove $(PROVE_ARGS)
	rm -rf t/openqa

.PHONY: all install
