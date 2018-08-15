FROM registry.opensuse.org/devel/openqa/containers/openqa_dev:latest
ENV LANG en_US.UTF-8

RUN sudo zypper --gpg-auto-import-keys -n ref --force && sudo zypper up -l -y

COPY entrypoint.sh /usr/bin/entrypoint
RUN ["sudo","chmod","+x","/usr/bin/entrypoint"]
USER ${NORMAL_USER}
ENTRYPOINT ["entrypoint"]
