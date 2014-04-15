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
use Try::Tiny;

use db_helpers;

__PACKAGE__->table('jobs');
__PACKAGE__->load_components(qw/InflateColumn::DateTime/);
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
    clone_id => {
        data_type => 'integer',
        is_foreign_key => 1,
        is_nullable => 1
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
__PACKAGE__->belongs_to(clone => 'Schema::Result::Jobs', 'clone_id', { join_type => 'left', on_delete => 'SET NULL' });
__PACKAGE__->might_have(origin => 'Schema::Result::Jobs', 'clone_id', { cascade_delete => 0 });
__PACKAGE__->has_many(jobs_assets => 'Schema::Result::JobsAssets', 'job_id');
__PACKAGE__->many_to_many(assets => 'jobs_assets', 'asset');

__PACKAGE__->add_unique_constraint(constraint_name => [qw/slug/]);

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    db_helpers::create_auto_timestamps($sqlt_table->schema, __PACKAGE__->table);
}

sub name{
    my $self = shift;
    return $self->slug if $self->slug;

    if (!$self->{_name}) {
        my $job_settings = $self->settings;
        my @a;

        my %s;
        while(my $js = $job_settings->next) {
            $s{lc $js->key} = $js->value;
        }

        my %formats = (build => 'Build%s',);

        for my $c (qw/distri version flavor media arch build test/) {
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

sub machine{
    my $self = shift;

    if (!defined($self->{_machine})) {
        my $setting = $self->settings({key => 'MACHINE'})->first;

        if ($setting) {
            $self->{_machine} = $setting->value;
        }
        else {
            $self->{_machine} = '';
        }
    }
    return $self->{_machine};
}

=head2 can_be_duplicated

=over

=item Arguments: none

=item Return value: 1 if a new clon can be created. 0 otherwise.

=back

Checks if a given job can be duplicated.

=cut
sub can_be_duplicated{
    my $self = shift;

    $self->clone ? 0 : 1;
}

=head2 duplicate

=over

=item Arguments: optional hash reference containing the key 'prio'

=item Return value: the new job if duplication suceeded, undef otherwise

=back

Clones the job creating a new one with the same settings and linked through
the 'clone' relationship. This method uses optimistic locking and database
transactions to ensure that only one clone is created per job. If the job
already have a job or the creation fails (most likely due to a concurrent
duplication detected by the optimistic locking), the method returns undef.

=cut
sub duplicate{
    my $self = shift;
    my $args = shift || {};
    my $rsource = $self->result_source;
    my $schema = $rsource->schema;

    # If the job already have a clone, none is created
    return undef unless $self->can_be_duplicated;

    # Code to be executed in a transaction to perform optimistic locking on
    # clone_id
    my $coderef = sub {
        # Duplicate settings (except NAME and TEST)
        my @new_settings;
        my $settings = $self->settings;

        while(my $js = $settings->next) {
            unless ($js->key eq 'NAME' || $js->key eq 'TEST') {
                push(@new_settings, { key => $js->key, value => $js->value });
            }
        }
        push(@new_settings, {key => 'TEST', value => $self->test});
        # TODO: test_branch

        my $new_job = $rsource->resultset->create(
            {
                test => $self->test,
                settings => \@new_settings,
                priority => $args->{prio} || $self->priority,
                jobs_assets => [ map { { asset => { id => $_->asset_id } } } $self->jobs_assets->all() ],
            }
        );
        # Perform optimistic locking on clone_id. If the job is not longer there
        # or it already has a clone, rollback the transaction (new_job should
        # not be created, somebody else was faster at cloning)
        my $upd = $rsource->resultset->search({clone_id => undef, id => $self->id})->update({clone_id => $new_job->id});

        die('There is already a clone!') unless ($upd == 1); # One row affected
        return $new_job;
    };

    my $res;

    try {
        $res = $schema->txn_do($coderef);
        $res->discard_changes; # Needed to load default values from DB
    }
    catch {
        my $error = shift;
        die "Rollback failed during failed job cloning!"
          if ($error =~ /Rollback failed/);
        $res = undef;
    };
    return $res;
}

1;
# vim: set sw=4 et:
