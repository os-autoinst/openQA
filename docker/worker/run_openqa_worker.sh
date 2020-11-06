#!/bin/bash
set -e

/root/qemu/kvm-mknod.sh
su _openqa-worker -c /usr/share/openqa/script/worker --verbose --instance "$OPENQA_WORKER_INSTANCE"
