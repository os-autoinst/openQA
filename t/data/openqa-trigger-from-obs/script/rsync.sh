[ "$1" != MockProjectLongProcessing ] || { echo "Sleeping $1"; sleep 4; }
[ "$1" != MockProjectLongProcessing1 ] || { echo "Sleeping $1"; sleep 4; }
[ "$1" != MockProjectError ] || { >&2 echo "Mock Error";  exit 1; }
echo MOCK OK $1
