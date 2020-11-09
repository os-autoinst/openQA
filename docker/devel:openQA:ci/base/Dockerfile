#!BuildTag: base
#!UseOBSRepositories
# preserve layers to prevent circleCI failing to download single big blobs,
# see https://progress.opensuse.org/issues/67855
#!NoSquash
FROM opensuse/leap:15.2

RUN zypper -n in openQA-devel

ENV LANG en_US.UTF-8

ENV NORMAL_USER squamata
ENV USER squamata

RUN echo "$NORMAL_USER ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
RUN useradd -r -d /home/$NORMAL_USER -m -g users --uid=1000 $NORMAL_USER

RUN mkdir -p /opt/testing_area
RUN chown -R $NORMAL_USER:users /opt/testing_area

WORKDIR /opt/testing_area
USER squamata
