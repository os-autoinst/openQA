#!/bin/bash
set -e

if [[ -z $OPENQA_WORKER_INSTANCE ]]; then
  OPENQA_WORKER_INSTANCE=1
fi

/root/qemu/kvm-mknod.sh
su _openqa-worker -c "/usr/share/openqa/script/worker --verbose --instance \"$OPENQA_WORKER_INSTANCE\""
