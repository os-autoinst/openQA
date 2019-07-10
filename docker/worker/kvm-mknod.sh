#!/bin/bash
# If possible, create the /dev/kvm device node.

set -e

test $(gunzip -c /proc/config.gz | grep CONFIG_KVM=y) || lsmod | grep '\<kvm\>' > /dev/null || {
  echo >&2 "KVM module not loaded; software emulation will be used"
  exit 1
}

mknod /dev/kvm c 10 $(grep '\<kvm\>' /proc/misc | cut -f 1 -d' ') || {
  echo >&2 "Unable to make /dev/kvm node; software emulation will be used"
  echo >&2 "(This can happen if the container is run without -privileged)"
  exit 1
}
