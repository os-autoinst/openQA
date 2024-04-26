FROM opensuse/tumbleweed:latest

RUN zypper in -y asciinema bat cargo gcc make fira-code-fonts jq retry wget
RUN cargo install autocast && \
    ln -s /root/.cargo/bin/autocast /usr/local/bin/
RUN cargo install --git https://github.com/asciinema/agg && \
    ln -s /root/.cargo/bin/agg /usr/local/bin/

RUN mkdir -p /work
VOLUME /work
WORKDIR /work
