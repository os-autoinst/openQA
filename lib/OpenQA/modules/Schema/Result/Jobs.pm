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

package Schema::Result::Jobs;
use base qw/DBIx::Class::Core/;

use db_helpers;

__PACKAGE__->table('jobs');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    slug => {
        data_type => 'text',
        is_nullable => 1,
    },
    state_id => {
        data_type => 'integer',
        is_foreign_key => 1,
        default_value => 0,
    },
    priority => {
        data_type => 'integer',
        default_value => 50,
    },
    result_id => {
        data_type => 'integer',
        default_value => 0,
	is_foreign_key => 1,
    },
    worker_id => {
        data_type => 'integer',
        is_foreign_key => 1,
        # FIXME: get rid of worker 0
        default_value => 0,
#        is_nullable => 1,
    },
    test => {
        data_type => 'text',
    },
    test_branch => {
        data_type => 'text',
        is_nullable => 1,
    },

    t_started => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    t_finished => {
        data_type => 'timestamp',
        is_nullable => 1,
    },

    t_created => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    t_updated => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(settings => 'Schema::Result::JobSettings', 'job_id');
__PACKAGE__->belongs_to(state => 'Schema::Result::JobStates', 'state_id');
__PACKAGE__->belongs_to(worker => 'Schema::Result::Workers', 'worker_id');
__PACKAGE__->belongs_to(result => 'Schema::Result::JobResults', 'result_id');

__PACKAGE__->add_unique_constraint(constraint_name => [ qw/slug/ ]);

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    db_helpers::create_auto_timestamps($sqlt_table->schema, __PACKAGE__->table);
}

sub name
{
    my $self = shift;
    return $self->slug if $self->slug;

    if (!$self->{_name}) {
        my $job_settings = $self->settings;
        my @a;

        my %s;
        while(my $js = $job_settings->next) {
            $s{lc $js->key} = $js->value;
        }

        my %formats = (
            build => 'Build%s',
        );

        for my $c (qw/distri version media arch build test/) {
            next unless $s{$c};
            push @a, sprintf(($formats{$c}||'%s'), $s{$c});
        }
        $self->{_name} = join('-', @a);
        if ($self->test_branch) {
            $self->{_name} .= '@'.$self->test_branch;
        }
    }
    return $self->{_name};
}

1;
