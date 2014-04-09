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
use base qw/DBIx::Class::Schema/;
use IO::Dir;
use SQL::SplitStatement;
use Fcntl ':mode';

our $VERSION = '5';

__PACKAGE__->load_namespaces;

sub execute_sql_file {
    my ( $class, $sqlfile ) = @_;
    print "Executing SQL statements from: $sqlfile\n";

    open my $fh, '<', $sqlfile or die "error opening $sqlfile: $!";
    my $contents = do { local $/; <$fh> };

    my $sql_splitter = SQL::SplitStatement->new;
    my @statements = $sql_splitter->split($contents);

    my $dbh = DBI->connect("dbi:SQLite:dbname=$openqa::dbfile") or die $DBI::errstr;
    $dbh->do("BEGIN TRANSACTION");
    foreach (@statements) {
        print "$_\n";

        unless ($dbh->do($_)) {
            print "ROLLBACK;\n";
            $dbh->do("ROLLBACK");
            die;
        }
    }
    $dbh->do("COMMIT");
}

sub deploy_fixtures {
    my ( $class, $attrs ) = @_;

    # insert pre-defined values to job_states
    $class->storage->dbh_do(
        sub {
            my ($storage, $dbh, @values) = @_;
            for my $i (0 .. $#values) {
                $dbh->do(sprintf("INSERT INTO job_states VALUES(%s, '%s');", $i, $values[$i]));
            }
        },
        (qw/scheduled running cancelled waiting done/)
    );

    # insert pre-defined values to job_results
    $class->storage->dbh_do(
        sub {
            my ($storage, $dbh, @values) = @_;
            for my $i (0 .. $#values) {
                $dbh->do(sprintf("INSERT INTO job_results VALUES(%s, '%s');", $i, $values[$i]));
            }
        },
        (qw/none passed failed incomplete/)
    );

    # prepare worker table
    # XXX: get rid of worker zero at some point
    $class->storage->dbh_do(
        sub {
            my ($storage, $dbh, @values) = @_;
            $dbh->do("INSERT INTO workers (id, host, instance, backend) VALUES(0, 'NONE', 0, 'NONE');");
        }
    );

    # Deploy fixtures specified statically in the fixtures directory
    my $script_directory = "$FindBin::Bin/../dbicdh";
    my %fixture_deploy_dir;
    tie %fixture_deploy_dir, 'IO::Dir', "$script_directory/fixtures/deploy/$VERSION";

    foreach (keys %fixture_deploy_dir) {
        if ( S_ISREG($fixture_deploy_dir{$_}->mode) ) {
            $class->execute_sql_file("$script_directory/fixtures/deploy/$VERSION/$_");
        }
    }

    return 0;
}

1;
# vim: set sw=4 et:
