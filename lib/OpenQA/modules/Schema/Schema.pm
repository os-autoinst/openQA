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

our $VERSION = '3';

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
# Local Variables:
# mode: cperl
# cperl-close-paren-offset: -4
# cperl-continued-statement-offset: 4
# cperl-indent-level: 4
# cperl-indent-parens-as-block: t
# cperl-tab-always-indent: t
# indent-tabs-mode: nil
# End:
# vim: set ts=4 sw=4 sts=4 et:
