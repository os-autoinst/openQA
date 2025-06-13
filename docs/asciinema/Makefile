YAML_FILES=$(wildcard *.yaml)
WEBM_FILES=$(YAML_FILES:.yaml=.webm)
THEME=monokai
BAT_THEME=Monokai Extended

.PHONY: all
all: build run

.PHONY: cast
cast: $(WEBM_FILES)

%.cast:%.yaml
	autocast --overwrite $< $@

%.gif: %.cast
	agg --theme $(THEME) $< $@

%.webm: %.gif
	ffmpeg -i $< -c:v libvpx-vp9 -b:v 0 -crf 30 -pix_fmt yuv420p $@

.PHONY: build
build:
	podman build . -t autocast

.PHONY: run
run:
	podman run -e BAT_THEME="$(BAT_THEME)" --rm -ti -v .:/work --privileged --device /dev/kvm autocast make cast
