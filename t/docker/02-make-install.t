#!script/test-in-container.sh
set -e
OUT=$(mktemp) || { echo "Failed to create temp file"; exit 1; }
sudo make install >/dev/null 2>$OUT || { echo "Command `make install` failed"; exit 1; }

[ -s $OUT ] || exit 0

echo 'FAIL: make install' prints errors
cat $OUT 
exit 1
