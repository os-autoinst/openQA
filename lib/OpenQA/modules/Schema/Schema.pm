package Schema;
use base qw/DBIx::Class::Schema/;

our $VERSION = '1';

__PACKAGE__->load_namespaces;

sub deploy {
    my ( $class, $attrs ) = @_;

    my $ret = $class->next::method($attrs);

    # insert pre-defined values
    $class->storage->dbh_do(
	sub {
	    my ($storage, $dbh, @states) = @_;
	    for my $i (0 .. $#states) {
		$dbh->do(sprintf ("INSERT INTO job_states VALUES(%s, '%s');", $i, $states[$i]));
	    }
	    # XXX: get rid of worker zero at some point
	    $dbh->do("INSERT INTO workers (id, host, instance, backend) VALUES(0, 'NONE', 0, 'NONE');");
	},
	(qw/scheduled running cancelled waiting done/)
    );

    return $ret;
}

1;
