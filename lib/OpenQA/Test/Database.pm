#
# Stolen from https://github.com/tempire/MojoExample
# TODO: Contact author to make sure that's OK
#

package OpenQA::Test::Database;

use strict;
use warnings;
use Carp;
use Cwd qw/ abs_path getcwd /;
use awstandard;
use openqa;
use Mojo::Base -base;
has fixture_path => 't/fixtures';

sub create {
  my $self        = shift;
  my %options     = (
    file    =>  $ENV{OPENQA_DB} || ':memory:',
    skip_fixtures  => 0,
    @_
  );
  my $file = $options{file};

  # Remove previous
  unlink $file if -e $file;

  # New db
  my $dsn = "dbi:SQLite:dbname=$file";
  my $schema = Schema->connect($dsn, '', '', {quote_char => '`', name_sep => '.'});
  $schema->deploy({quote_table_names => 1, quote_field_names => 1});

  # Fixtures
  $self->insert_fixtures($file, $schema) unless $options{skip_fixtures};

  return $schema;
}

sub insert_fixtures {
  my $self   = shift;
  my $file   = shift;
  my $schema = shift;

  # Store working dir
  my $cwd = getcwd;

  chdir $self->fixture_path;

  foreach my $fixture (<*.pl>) {

    my $info = eval file_content $fixture;
    chdir $cwd, croak "Could not insert fixture $fixture: $@" if $@;

    # Arrayrefs of rows, (dbic syntax) table defined by fixture filename
    if (ref $info->[0] eq 'HASH') {
      my $rs_name = (split /\./, $fixture)[0];
      $rs_name =~ s/s$//;

      # list context, so that populate uses dbic ->insert overrides
      my @noop = $schema->resultset(ucfirst $rs_name)->populate($info);

      next;
    }

    # Arrayref of hashrefs, multiple tables per file
    for (my $i = 0; $i < @$info; $i++) {
      $schema->resultset($info->[$i])->create($info->[++$i]);
    }
  }

  # Restore working dir
  chdir $cwd;
}

sub disconnect {
  return shift->storage->dbh->disconnect;
}

1;

=head1 NAME

Test::Database

=head1 DESCRIPTION

Deploy schema & load fixtures

=head1 USAGE

    # Creates an sqlite3 test.db database from DBIC Schema without fixtures
    my $schema = Test::Database->new->create(file => 'test.db', skip_fixtures => 1);

    # Creates an in-memory sqlite3 database from DBIC Schema (both are equivalent)
    my $schema = Test::Database->new->create(file => ':memory:');
    my $schema = Test::Database->new->create;

=head1 METHODS

=head2 create (%args)

Create new sqlite3 database from DBIC schema. Use file to specify the filename
(or ':memory:') and skip_fixtures to prevent loading fixtures.

=head2 insert_fixtures

Insert fixtures into sqlite3 database

=head2 disconnect ($schema)

Disconnect from database handle

=cut
