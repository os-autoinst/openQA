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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Schema;
use base qw/DBIx::Class::Schema/;
use Config::IniFiles;
use IO::Dir;
use SQL::SplitStatement;
use Fcntl ':mode';
use FindBin qw($Bin);

# after bumping the version please look at the instructions in the docs/Contributing.asciidoc file
# on what scripts should be run and how
our $VERSION = 29;

__PACKAGE__->load_namespaces;




sub connect_db {
    my $mode = shift || $ENV{OPENQA_DATABASE} || 'production';
    CORE::state $schema;
    unless ($schema) {
        my %ini;
        my $cfgpath=$ENV{OPENQA_CONFIG} || "$Bin/../etc/openqa";
        tie %ini, 'Config::IniFiles', ( -file => $cfgpath.'/database.ini' );
        $schema=__PACKAGE__->connect($ini{$mode});
    }
    return $schema;
}

sub dsn {
    my $self = shift;

    $self->storage->connect_info->[0]->{dsn};
}

1;
# vim: set sw=4 et:
