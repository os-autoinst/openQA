# hadolint ignore=DL3007
FROM registry.opensuse.org/devel/openqa/containers15.3/openqa_dev:latest
ENV LANG en_US.UTF-8

COPY entrypoint.sh /usr/bin/entrypoint
# don't know how to replace sudo with other calls right now
# hadolint ignore=DL3004
RUN ["sudo","chmod","+x","/usr/bin/entrypoint"]
USER ${NORMAL_USER}
ENTRYPOINT ["entrypoint"]
