#!/bin/bash

mkdir -p perl testresults testrun-manual factory/iso video
(cd perl ; git clone git://gitorious.org/os-autoinst/os-autoinst.git autoinst )

# part of the install needs to be done as root
sudo tools/rootsetup.sh

