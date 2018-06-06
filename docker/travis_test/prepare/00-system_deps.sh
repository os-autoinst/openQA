#!/bin/bash -xv

echo "#######################################################"
echo "#          Starting build tools installation          #"
echo "#######################################################"

zypper ar -p 1 -f -G "https://download.opensuse.org/repositories/devel:/openQA:/Leap:/42.3/openSUSE_Leap_42.3/devel:openQA:Leap:42.3.repo"
zypper ref
zypper dup -y

zypper in -y -C automake \
       curl \
       dbus-1-devel \
       fftw3-devel \
       gcc \
       gcc-c++ \
       git \
       gmp-devel \
       gzip \
       libexpat-devel \
       libsndfile-devel \
       libssh2-1 \
       libssh2-devel \
       libtheora-devel \
       libtool \
       libxml2-devel \
       make \
       opencv-devel \
       patch \
       postgresql-devel \
       qemu \
       qemu-tools \
       qemu-kvm \
       tar \
       optipng \
       sqlite3 \
       postgresql-server \
       which \
       chromedriver \
       'rubygem(sass)' \
        perl
