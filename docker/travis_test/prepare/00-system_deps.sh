#!/bin/bash

echo "#######################################################"
echo "#          Starting build tools installation          #"
echo "#######################################################"

zypper up -y
zypper in -y automake \
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
       perl-App-cpanminus \
       postgresql96-devel \
       qemu-x86 \
       tar \
       postgresql96-server \
       which \
       findutils\
       ruby2.4-rubygem-sass \
       chromedriver



