#!script/test-in-container-privileged.sh

set -e
sudo make install
sudo /lib/apparmor/apparmor.systemd restart 
sudo aa-enforce /usr/share/openqa/script/openqa
