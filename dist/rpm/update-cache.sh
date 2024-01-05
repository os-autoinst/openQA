#! /bin/sh

# Note: this might not work correctly anymore because the 'lr' command
# was obsoleted.

set -e

export LC_ALL='en_US.UTF-8'
export LANG='en_US.UTF-8'
osc up
rm -f _service\:*
rm -f *.tar *.cpio
osc service lr
# special call for tar buildtime service
osc service run tar

SD=$PWD
cd openQA
tools/generate-packed-assets
tar cvjf cache.tar.xz assets/cache assets/assetpack.db
mv cache.tar.xz "$SD/cache.txz"

cd "$SD"
osc up
