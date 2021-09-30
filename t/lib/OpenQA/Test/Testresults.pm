# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Test::Testresults;
use Mojo::Base -base;

use File::Copy::Recursive 'dircopy';
use File::Path 'remove_tree';
use OpenQA::Utils qw(:DEFAULT resultdir);

sub create {
    my $self = shift;
    my %options = (
        directory => undef,
        @_
    );

    if ($options{directory}) {
        # Remove previous
        remove_tree(resultdir()) if -e resultdir();
        # copy new
        dircopy($options{directory}, resultdir()) or die $!;
    }

    return resultdir();
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
