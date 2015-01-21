# Copyright (C) 2014 SUSE Linux Products GmbH
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

package Schema;
use base qw/DBIx::Class::Schema::Config/;
use IO::Dir;
use File::Basename qw/dirname/;
use SQL::SplitStatement;
use Fcntl ':mode';
use FindBin qw($Bin);

# after bumping the version please look at the instructions in the docs/Contributing.asciidoc file
# on what scripts should be run and how
our $VERSION = 23;

__PACKAGE__->load_namespaces;

my @paths = ( "$Bin/../lib/database", "$Bin/../../lib/database" );
unshift(@paths, dirname($ENV{OPENQA_CONFIG}).'/database') if ($ENV{OPENQA_CONFIG});
__PACKAGE__->config_paths(\@paths);

sub dsn {
    my $self = shift;

    $self->storage->connect_info->[0]->{dsn};
}

1;
# vim: set sw=4 et:
