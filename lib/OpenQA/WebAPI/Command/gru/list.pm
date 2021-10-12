# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Command::gru::list;
use Mojo::Base 'Minion::Command::minion::job';

has description => 'List Gru jobs and more';
has usage => sub { shift->extract_usage };

1;

=encoding utf8

=head1 NAME

OpenQA::WebAPI::Command::gru::list - Gru list command

=head1 SYNOPSIS

  Usage: APPLICATION gru list [OPTIONS] [IDS]

    script/openqa gru list

  Options:
    See 'script/openqa minion job -h' for all available options.

=head1 DESCRIPTION

L<OpenQA::WebAPI::Command::gru::list> is a subclass of
L<Minion::Command::minion::job> that merely renames the command for backwards
compatibility.

=cut
