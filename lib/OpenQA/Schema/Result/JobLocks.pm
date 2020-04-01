# Copyright (C) 2015 SUSE LLC
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

package OpenQA::Schema::Result::JobLocks;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->load_components(qw(OptimisticLocking Core));
__PACKAGE__->load_components(qw(Core));
__PACKAGE__->table('job_locks');
__PACKAGE__->add_columns(
    name => {
        data_type   => 'text',
        is_nullable => 0,
    },
    owner => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 0,
    },
    locked_by => {
        data_type     => 'text',
        is_nullable   => 1,
        default_value => undef,
    },
    count => {
        data_type     => 'integer',
        default_value => 1,
        is_nullable   => 0
    });

__PACKAGE__->set_primary_key('name', 'owner');
__PACKAGE__->belongs_to(owner => 'OpenQA::Schema::Result::Jobs', 'owner');


# translate job ids stored in locked_by to jobs
sub locked_by_jobs {
    my ($self)  = @_;
    my $rsource = $self->result_source;
    my $schema  = $rsource->schema;

    return unless $self->locked_by;
    my @locked_ids = split(/,/, $self->locked_by);
    return $schema->resultset('Jobs')->search({id => {-in => \@locked_ids}})->all;
}

1;
