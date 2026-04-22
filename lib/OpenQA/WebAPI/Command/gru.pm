# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Command::gru;
use Mojo::Base 'Mojolicious::Commands', -signatures;

has description => 'Gru job queue';
has hint => <<'EOF';
See 'APPLICATION gru help COMMAND' for more information on a specific
command.
EOF
has message => sub ($self) { $self->extract_usage . "\nCommands:\n" };
has namespaces => sub ($self) { ['OpenQA::WebAPI::Command::gru'] };

sub help ($self, @args) { $self->run(@args) }

1;

=encoding utf8

=head1 NAME

OpenQA::WebAPI::Command::gru - gru command

=head1 SYNOPSIS

  Usage: APPLICATION gru COMMAND [OPTIONS]

=head1 DESCRIPTION

L<OpenQA::WebAPI::Command::gru> lists available Gru commands.

=cut
