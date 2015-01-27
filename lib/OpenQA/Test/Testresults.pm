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

package OpenQA::Test::Testresults;

use File::Copy::Recursive qw/dircopy/;
use File::Path qw/remove_tree/;
use OpenQA::Utils;
use Mojo::Base -base;

sub create {
    my $self        = shift;
    my %options     = (
        directory  => undef,
        @_
    );

    if ($options{directory}) {
        # Remove previous
        remove_tree($OpenQA::Utils::resultdir) if -e $OpenQA::Utils::resultdir;
        # copy new
        dircopy($options{directory}, $OpenQA::Utils::resultdir) or die $!;
    }

    return $OpenQA::Utils::resultdir;
}

1;

=head1 NAME

OpenQA::Test::Testresults

=head1 DESCRIPTION

Copy a testresults directory

=head1 USAGE

    # Copy the given directory into the test data directory
    Test::Testresults->new->create(directory => 'one_testresults')

=head1 METHODS

=head2 create (%args)

Copy the given directory to the location used as testresults by running tests.

=cut
# vim: set sw=4 et:
