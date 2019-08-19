[ "$1" != MockProjectLongProcessing ] || { echo "Sleeping $1"; sleep 2; }
[ "$1" != MockProjectLongProcessing1 ] || { echo "Sleeping $1"; sleep 2; }
echo MOCK OK $1
