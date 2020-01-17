# Copyright (C) 2020 SUSE Software Solutions Germany GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Mojo::Base -strict;

use File::Temp qw(tempfile);
use Mojo::File qw(path curfile);
use Test::More;
use Test::Output;
use Test::Warnings;

sub run_once {
    my ($args) = @_;
    my $script = path(curfile->dirname, '../script/load_templates')->realpath;
    system("$script $args") >> 8;
}

my $ret;
my $args = '';
combined_like(sub { $ret = run_once($args) }, qr/Usage:/, 'help text shown');
is $ret, 1, 'load_templates with no arguments shows usage';

$args = "--host";
combined_like(sub { $ret = run_once($args) }, qr/Option host requires an argument/, 'host argument error shown');

my $host     = 'testhost:1234';
my $filename = 't/data/40-templates.pl';
$args = "--host $host $filename";
combined_like sub { $ret = run_once($args); }, qr/unknown error code - host $host unreachable?/, 'invalid host error';
is $ret, 22, 'error because host is invalid';

done_testing;
