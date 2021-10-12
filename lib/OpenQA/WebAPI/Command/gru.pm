# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Command::gru;
use Mojo::Base 'Mojolicious::Commands';

has description => 'Gru job queue';
has hint => <<EOF;
See 'APPLICATION gru help COMMAND' for more information on a specific
command.
EOF
has message => sub { shift->extract_usage . "\nCommands:\n" };
has namespaces => sub { ['OpenQA::WebAPI::Command::gru'] };

sub help { shift->run(@_) }

1;

=encoding utf8

=head1 NAME

OpenQA::WebAPI::Command::gru - gru command

=head1 SYNOPSIS

  Usage: APPLICATION gru COMMAND [OPTIONS]

=head1 DESCRIPTION

L<OpenQA::WebAPI::Command::gru> lists available Gru commands.

=cut
