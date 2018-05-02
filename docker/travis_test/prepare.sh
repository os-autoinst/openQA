#!/bin/bash

export DIR="${BASH_SOURCE%/*}/prepare"

. "$DIR/00-system_deps.sh";

. "$DIR/01-perl_deps.sh";
