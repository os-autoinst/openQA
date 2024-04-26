YAML_FILES=$(wildcard *.yaml)
GIF_FILES=$(YAML_FILES:.yaml=.gif)
THEME=monokai
BAT_THEME=Monokai Extended

.PHONY: all
all: build run

.PHONY: cast
cast: $(GIF_FILES)

%.cast:%.yaml
	autocast --overwrite $< $@

%.gif: %.cast
	agg --theme $(THEME) $< $@

.PHONY: build
build:
	podman build . -t autocast

.PHONY: run
run:
	podman run -e BAT_THEME="$(BAT_THEME)" --rm -ti -v .:/work --privileged --device /dev/kvm autocast make cast
