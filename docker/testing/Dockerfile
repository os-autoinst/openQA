# Docker file to test full-stack.t in a travis like environment
FROM ubuntu:12.04
run apt-get -y update
run apt-get -y install software-properties-common
run add-apt-repository -y ppa:kubuntu-ppa/backports
run apt-get -y update
run apt-get -y install libdbus-1-dev libssh2-1-dev libopencv-dev libtheora-dev libcv-dev libhighgui-dev tesseract-ocr libsndfile1-dev libfftw3-dev qemu-system automake libtool libxml2-dev libgmp3-dev ruby-sass git libssl-dev libgcrypt11-dev curl wget
# mirrored as the original URL is very unreliable
run curl http://stephan.kulow.org/phantomjs-2.1.1-linux-x86_64.tar.bz2 | tar xvjf -
run mv phantomjs-2.1.1-linux-x86_64/bin/phantomjs /usr/bin
run rm -r phantomjs-2.1.1-linux-x86_64
run git clone https://github.com/os-autoinst/openQA.git
run git clone https://github.com/os-autoinst/os-autoinst.git
run curl -L https://install.perlbrew.pl | bash
run ~/perl5/perlbrew/bin/perlbrew install -n perl-5.18.2
run curl -L https://cpanmin.us | ~/perl5/perlbrew/bin/perlbrew exec perl - App::cpanminus  
run git config --global user.email "you@example.com"
run git config --global user.name "Your Name"
copy perlw /root/bin/perlw
run cd os-autoinst && /root/bin/perlw "cpanm -n --installdeps --with-feature=coverage ."
run cd os-autoinst && /root/bin/perlw ./autogen.sh && /root/bin/perlw make
run cd openQA && /root/bin/perlw "cpanm -nq --installdeps --with-feature=coverage ."
# prefetch assets
run cd openQA && /root/bin/perlw "perl t/06-users.t"
run apt-get -y install dbus-x11 dbus strace vim
copy test.sh /
