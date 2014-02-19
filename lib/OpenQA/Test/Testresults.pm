package OpenQA::Test::Testresults;

use File::Copy::Recursive qw/dircopy/;
use File::Path qw/remove_tree/;
use openqa;
use Mojo::Base -base;

sub create {
  my $self        = shift;
  my %options     = (
    directory  => undef,
    @_
  );

  if ($options{directory}) {
          # Remove previous
          remove_tree($openqa::resultdir) if -e $openqa::resultdir;
          # copy new
          dircopy($options{directory}, $openqa::resultdir) or die $!;
  }

  return $openqa::resultdir;
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
