#!/bin/bash
# shellcheck disable=SC2012
set -e

if [[ -z $OPENQA_WORKER_INSTANCE ]]; then
  OPENQA_WORKER_INSTANCE=1
fi

/root/qemu/kvm-mknod.sh

if [ -e "/dev/kvm" ] && getent group kvm > /dev/null; then
  groupmod -g "$(ls -lhn /dev/kvm | cut -d ' ' -f 4)" kvm
  usermod -a -G kvm _openqa-worker
else
  echo "Warning: /dev/kvm doesn't exist. If you want to use KVM, run the container with --device=/dev/kvm"
fi

su _openqa-worker -c "/usr/share/openqa/script/worker --verbose --instance \"$OPENQA_WORKER_INSTANCE\""
