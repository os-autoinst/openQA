# Copyright 2018 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::WebAPI::Command::gru;
use Mojo::Base 'Mojolicious::Commands';

has description => 'Gru job queue';
has hint        => <<EOF;
See 'APPLICATION gru help COMMAND' for more information on a specific
command.
EOF
has message    => sub { shift->extract_usage . "\nCommands:\n" };
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
