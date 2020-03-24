# Copyright (C) 2020 SUSE LLC
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

package OpenQA::CLI::archive;
use Mojo::Base 'OpenQA::Command';

has description => 'Download assets and test results from a job';
has usage       => sub { shift->extract_usage };

sub run {
    my ($self, @args) = @_;

    die "Not yet implemented!\n";
}

1;

=encoding utf8

=head1 SYNOPSIS

  Usage: openqa-cli archive [OPTIONS]

    openqa-cli archive ...

  Options:
        --apikey <key>          API key
        --apisecret <secret>    API secret
    -h, --help                  Show this summary of available options

=cut
