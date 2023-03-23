#!BuildTag: tumbleweed:client
# This container is built on https://build.opensuse.org/package/show/devel:openQA/openQA_container_client.

# hadolint ignore=DL3007
FROM opensuse/tumbleweed:latest

# hadolint ignore=DL3037
RUN zypper ar -p 95 -f https://download.opensuse.org/repositories/devel:/openQA/openSUSE_Tumbleweed devel_openQA && \
    zypper --gpg-auto-import-keys ref && \
    zypper in -y openQA-client git && \
    zypper clean