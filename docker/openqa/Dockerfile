FROM registry.opensuse.org/devel/openqa/containers/openqa_dev:latest
ENV LANG en_US.UTF-8
COPY dependencies /dependencies.new
RUN diff -q /dependencies{,.new} || sudo xargs -a /dependencies.new zypper --no-gpg-checks --no-refresh -n in -C
COPY entrypoint.sh /usr/bin/entrypoint
RUN ["sudo","chmod","+x","/usr/bin/entrypoint"]
USER ${NORMAL_USER}
ENTRYPOINT ["entrypoint"]
