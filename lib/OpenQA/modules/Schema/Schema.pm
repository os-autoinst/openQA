package Schema;
use base qw/DBIx::Class::Schema/;

our $VERSION = '2';

__PACKAGE__->load_namespaces;

sub deploy {
    my ( $class, $attrs ) = @_;

    my $ret = $class->next::method($attrs);

    # insert pre-defined values to job_states
    $class->storage->dbh_do(
	sub {
	    my ($storage, $dbh, @values) = @_;
	    for my $i (0 .. $#values) {
		$dbh->do(sprintf ("INSERT INTO job_states VALUES(%s, '%s');", $i, $values[$i]));
	    }
	},
	(qw/scheduled running cancelled waiting done/)
    );

    # insert pre-defined values to job_results
    $class->storage->dbh_do(
	sub {
	    my ($storage, $dbh, @values) = @_;
	    for my $i (0 .. $#values) {
		$dbh->do(sprintf ("INSERT INTO job_results VALUES(%s, '%s');", $i, $values[$i]));
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

    return $ret;
}

1;
