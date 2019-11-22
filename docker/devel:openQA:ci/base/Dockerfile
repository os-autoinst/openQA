#!BuildTag: base
#!UseOBSRepositories
FROM opensuse/leap:15.1

# these are autoinst dependencies
RUN zypper install -y autoconf automake gcc-c++ libtool pkgconfig\(opencv\) pkg-config perl\(Module::CPANfile\) pkgconfig\(fftw3\) pkgconfig\(libpng\) pkgconfig\(sndfile\) pkgconfig\(theoraenc\) make

# openQA dependencies
RUN zypper install -y rubygem\(sass\) python3-base python3-requests python3-future git-core rsync curl postgresql-devel postgresql-server qemu qemu-kvm qemu-tools tar sudo

# openQA test dependency - experimental
RUN zypper install -y chromedriver

ENV LANG en_US.UTF-8

ENV NORMAL_USER squamata
ENV USER squamata

RUN echo "$NORMAL_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
RUN mkdir -p /home/$NORMAL_USER
RUN useradd -r -d /home/$NORMAL_USER -g users --uid=1000 $NORMAL_USER
RUN chown $NORMAL_USER:users /home/$NORMAL_USER

RUN mkdir -p /opt/testing_area
RUN chown -R $NORMAL_USER:users /opt/testing_area

WORKDIR /opt/testing_area
USER squamata
