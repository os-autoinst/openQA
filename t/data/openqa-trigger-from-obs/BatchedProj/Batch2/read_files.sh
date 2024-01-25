thisdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

echo "openSUSE-Leap-15.1-DVD-x86_64-Snapshot4704-Media.iso" >"$thisdir"/files_iso.lst
echo "openSUSE-Leap-15.1-DVD-x86_64-Snapshot4703-Media.iso" >>"$thisdir"/files_iso.lst
