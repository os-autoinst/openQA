#!script/test-in-container.sh
: ${MODE:=production} ${SECTION:=production}

set -e
sudo make install 2>&1
sudo mkdir -p /usr/share/openqa/etc/openqa
sudo tee /usr/share/openqa/etc/openqa/database.ini << EOL
[$SECTION]
dsn = dbi:SQLite:dbname=:memory:
EOL

export PERL5LIB=/opt/test_area/lib

cerr=$(mktemp) 

(sudo /usr/share/openqa/script/openqa -m "$MODE" >/dev/null 2>$cerr) &
sleep 3

found=$(grep "Could not find database section" $cerr || :)

if [ "$MODE" = "$SECTION" ]; then
    [ -z "$found" ] || msg="Unexpected error message"
else
    [ -n "$found" ] || msg="Cannot find expected error"
fi

if [ -z "$msg" ]; then
    echo PASS
else
    echo "FAIL: $msg in mode '$MODE' with configured section [$SECTION]"
    exit 1
fi
