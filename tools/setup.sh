#!/bin/bash

mkdir perl
cd perl
git clone git://gitorious.org/os-autoinst/os-autoinst.git autoinst

mkdir -p testresults testrun-manual factory/iso
echo video/ogg ogv >> /etc/mime.types

