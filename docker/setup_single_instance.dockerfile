FROM opensuse_mocked_systemd/tumbleweed
RUN zypper ar -f -p 95 obs://devel:openQA/openSUSE_Tumbleweed devel-openQA
RUN systemctl enable openqa-setup-single-instance
CMD [ "/usr/bin/systemctl" ]
# run with e.g. " docker run --rm -it --tmpfs /tmp --tmpfs /run -v /sys/fs/cgroup:/sys/fs/cgroup:ro -v $PWD:/opt/openqa:ro opensuse_mocked_systemd/tumbleweed bash"
