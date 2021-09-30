# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI;
use Mojo::Base 'Mojolicious::Commands';

has hint => <<EOF;

See 'openqa-cli help COMMAND' for more information on a specific command.
EOF
has message => sub { shift->extract_usage . "\nCommands:\n" };
has namespaces => sub { ['OpenQA::CLI'] };

1;

=encoding utf8

=head1 NAME

openqa-cli - provides command-line access to the openQA API

=head1 SYNOPSIS

  Usage: openqa-cli COMMAND [OPTIONS]

    # Show api command help with all available options and more examples
    openqa-cli api --help

    # Show details for job from localhost
    openqa-cli api jobs/4160811

    # Show details for job from arbitrary host
    openqa-cli api --host http://openqa.example.com jobs/408

    # Show details for OSD job (prettified JSON)
    openqa-cli api --osd --pretty jobs/4160811

    # Archive job from O3
    openqa-cli archive --o3 408 /tmp/job_408

  Options (for all commands):
        --apibase <path>        API base, defaults to /api/v1
        --apikey <key>          API key
        --apisecret <secret>    API secret
        --host <host>           Target host, defaults to http://localhost
    -h, --help                  Get more information on a specific command
        --osd                   Set target host to http://openqa.suse.de
        --o3                    Set target host to https://openqa.opensuse.org

  Configuration:
    API key and secret are read from "client.conf" if not specified via CLI
    arguments. The config file is checked for under "$OPENQA_CONFIG",
    "~/.config/openqa" and "/etc/openqa" in this order. It must look like
    this:

      [openqa.opensuse.org]
      key = 45ABCEB4562ACB04
      secret = 4BA0003086C4CB95
      [another.host]
      key = D7345DA7B9D86B3B
      secret = A98CDBA9C8DB87BD

=cut
