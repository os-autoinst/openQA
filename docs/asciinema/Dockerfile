# syntax=docker/dockerfile:1.3
FROM opensuse/tumbleweed:latest

# Install recording prerequisites
RUN zypper in -y asciinema cargo gcc make fira-code-fonts ffmpeg
RUN cargo install autocast && \
    ln -s /root/.cargo/bin/autocast /usr/local/bin/
RUN cargo install --git https://github.com/asciinema/agg && \
    ln -s /root/.cargo/bin/agg /usr/local/bin/

# Install utilities used in the recording
RUN zypper in -y bat jq retry wget

# Use http://www.brow.sh to show the web in terminal
RUN zypper in -y firefox
RUN wget -O /usr/local/bin/browsh https://github.com/browsh-org/browsh/releases/download/v1.8.2/browsh_1.8.2_linux_amd64 && \
    chmod +x /usr/local/bin/browsh
RUN mkdir -p /root/.config/browsh
COPY <<EOF /root/.config/browsh/config.toml
browsh_supporter = "I have shown my support for Browsh"
[firefox]
path = "/usr/bin/firefox"
EOF

RUN mkdir -p /work
VOLUME /work
WORKDIR /work
