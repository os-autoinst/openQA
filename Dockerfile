# Docker file to test full-stack.t in a travis like environment
FROM sonarsource/local-travis
run wget https://bitbucket.org/ariya/phantomjs/downloads/phantomjs-2.1.1-linux-x86_64.tar.bz2 -O /p.tar.bz2
run tar xvjf /p.tar.bz2
run rm /p.tar.bz2
run mv phantomjs-2.1.1-linux-x86_64/bin/phantomjs /usr/bin
run apt-get -y update
run apt-get -y install libdbus-1-dev libssh2-1-dev libopencv-dev libtheora-dev libcv-dev libhighgui-dev tesseract-ocr libsndfile1-dev libfftw3-dev qemu-system automake libtool
run git clone https://github.com/os-autoinst/openQA.git
run git clone https://github.com/os-autoinst/os-autoinst.git
run apt-get -y install cpanminus
run apt-get -y install libxml2-dev
run cd os-autoinst && cpanm -nq --installdeps --with-feature=coverage .
run cd os-autoinst && sh autogen.sh && ./configure && make
run apt-get -y install libgmp3-dev libdbus-1-dev
run cd openQA && cpanm -nq --installdeps --with-feature=coverage .
run apt-get -y install ruby-sass
run cd openQA && perl t/06-users.t
run git config --global user.email "you@example.com"
run git config --global user.name "Your Name"
run cd openQA && git fetch origin && git checkout try_full_stack
copy t/full-stack.sh /

