#!BuildTag: base
#!UseOBSRepositories
# preserve layers to avoid failures in CircleCI while it downloads a big blob
# in one go
# see https://progress.opensuse.org/issues/67855
#!NoSquash
FROM opensuse/leap:15.3

# only dependencies for CircleCI to be able to load/save the package cache
# and fix permissions for the unprivileged user we use
RUN zypper -n in tar gzip sudo

# these are autoinst dependencies
RUN zypper install -y gcc-c++ cmake ninja pkgconfig\(opencv\) pkg-config perl\(Module::CPANfile\) pkgconfig\(fftw3\) pkgconfig\(libpng\) pkgconfig\(sndfile\) pkgconfig\(theoraenc\)

# openQA dependencies
RUN zypper install -y rubygem\(sass\) python3-base python3-requests python3-future git-core rsync curl postgresql-devel postgresql-server qemu qemu-kvm qemu-tools tar xorg-x11-fonts sudo make

# openQA chromedriver for Selenium tests
RUN zypper install -y chromedriver

ENV LANG en_US.UTF-8

ENV NORMAL_USER squamata
ENV USER squamata

RUN echo "$NORMAL_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
RUN useradd -r -d /home/$NORMAL_USER -m -g users --uid=1000 $NORMAL_USER

RUN mkdir -p /opt/testing_area
RUN chown -R $NORMAL_USER:users /opt/testing_area

WORKDIR /opt/testing_area
USER squamata
