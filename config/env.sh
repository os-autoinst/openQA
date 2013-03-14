#!/bin/sh

n=$(basename $(pwd))
test $n -gt 0 || n=99

# if you have something slower than Core i7 you might need to increase the IDLETHRESHOLD value... e.g. on my Phenom X4 I have 25 instead of 16
export IDLETHESHOLD=15

# default: 0.5 (two screenshots per second)
if test -z "$SCREENSHOTINTERVAL" ; then
	export SCREENSHOTINTERVAL=0.5
fi

#export HTTPPROXY=192.168.234.34:3128

# leave empty for http://download.opensuse.org/factory
#export SUSEMIRROR=http://dist.suse.de/ibs/SUSE%3A/SLE-11-SP2%3A/GA/standard/
#export SUSEMIRROR=http://openqa.opensuse.org/opensuse/factory-testing

# possible values: 0|1|5|6|10
#export RAIDLEVEL=6
# alternatively use Logical Volume Manager
#export LVM=1

# use random values for undefined testing variables
#RANDOMENV=1

# ignored for LiveCDs ; possible values: kde|gnome|xfce|lxde|minimalx|textmode
#export DESKTOP=gnome

# if you want to run this mostly for the video
#export NICEVIDEO=1

# is this a beta version with extra popup window on welcome screen?
export BETA=1

# if you want to run tests in parallel, you need to give different ports
# note that $QEMUPORT+1 is also used
export QEMUPORT=$(expr 20002 + $n \* 10)

# which VNC port to use. default is to allow vncviewer $HOSTNAME:99
export VNC=$(expr 90 + $n)
# VNC keyboard layout of vncclient machine
#export VNCKB=de

#export INSTLANG=de_DE
