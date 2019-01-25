FROM registry.opensuse.org/devel/openqa/containers/openqa_dev:latest
ENV LANG en_US.UTF-8

COPY entrypoint.sh /usr/bin/entrypoint
RUN ["sudo","chmod","+x","/usr/bin/entrypoint"]
# https://build.opensuse.org/request/show/668410
RUN zypper -n --no-gpg-checks in --no-recommends lsof
USER ${NORMAL_USER}
ENTRYPOINT ["entrypoint"]
