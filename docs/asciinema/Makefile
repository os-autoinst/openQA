YAML_FILES=$(wildcard *.yaml)
GIF_FILES=$(YAML_FILES:.yaml=.gif)
THEME=monokai

all: $(GIF_FILES)

%.cast:%.yaml
	autocast --overwrite $< $@

%.gif: %.cast
	agg --theme $(THEME) $< $@
