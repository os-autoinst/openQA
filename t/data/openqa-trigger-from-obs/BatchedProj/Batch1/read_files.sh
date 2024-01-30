thisdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1 && pwd)"

echo "openSUSE-Leap-15.1-DVD-x86_64-Build470.2-Media.iso" > "$thisdir"/files_iso.lst
echo "Build469.1" > "$thisdir"/Media1_ftp_ftp.lst
