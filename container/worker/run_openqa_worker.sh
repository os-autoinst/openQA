#!/bin/bash
# shellcheck disable=SC2012,SC2154
set -e

if [[ -z $OPENQA_WORKER_INSTANCE ]]; then
  OPENQA_WORKER_INSTANCE=1
fi

mkdir -p "/var/lib/openqa/pool/${OPENQA_WORKER_INSTANCE}/"
chown -R _openqa-worker /var/lib/openqa/pool/

if [[ -z $qemu_no_kvm ]] || [[ $qemu_no_kvm -eq 0 ]]; then
  if [ -e "/dev/kvm" ] && getent group kvm > /dev/null; then
    /root/qemu/kvm-mknod.sh

    group=$(ls -lhn /dev/kvm | cut -d ' ' -f 4)
    groupmod -g "$group" --non-unique kvm
    usermod -a -G kvm _openqa-worker
  else
    echo "Warning: /dev/kvm doesn't exist. If you want to use KVM, run the container with --device=/dev/kvm"
  fi
fi

qemu-system-x86_64 -S &
kill $!

# Install test distribution dependencies
find -L "/var/lib/openqa/share/tests" -maxdepth 2 -type f -executable -name 'install_deps.*' -exec {} \;

su _openqa-worker -c "/usr/share/openqa/script/worker --verbose --instance \"$OPENQA_WORKER_INSTANCE\""
