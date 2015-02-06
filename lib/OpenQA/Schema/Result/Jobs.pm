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

package OpenQA::Schema::Result::Jobs;
use base qw/DBIx::Class::Core/;
use Try::Tiny;

use db_helpers;

# States
use constant {
    SCHEDULED => 'scheduled',
    RUNNING => 'running',
    CANCELLED => 'cancelled',
    WAITING => 'waiting',
    DONE => 'done',
    OBSOLETED => 'obsoleted',
};
use constant STATES => ( SCHEDULED, RUNNING, CANCELLED, WAITING, DONE, OBSOLETED );
use constant PENDING_STATES => ( SCHEDULED, RUNNING, WAITING );
use constant EXECUTION_STATES => ( RUNNING, WAITING );

# Results
use constant {
    NONE => 'none',
    PASSED => 'passed',
    FAILED => 'failed',
    INCOMPLETE => 'incomplete',
    SKIPPED => 'skipped',
};
use constant RESULTS => ( NONE, PASSED, FAILED, INCOMPLETE, SKIPPED );

__PACKAGE__->table('jobs');
__PACKAGE__->load_components(qw/InflateColumn::DateTime Timestamps/);
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    slug => {
        data_type => 'text',
        is_nullable => 1,
    },
    state => {
        data_type => 'varchar',
        default_value => SCHEDULED,
    },
    priority => {
        data_type => 'integer',
        default_value => 50,
    },
    result => {
        data_type => 'varchar',
        default_value => NONE,
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
    clone_id => {
        data_type => 'integer',
        is_foreign_key => 1,
        is_nullable => 1
    },
    retry_avbl => {
        data_type => 'integer',
        default_value => 3,
    },
    backend_info => {
        # we store free text JSON here - backends might store random data about the job
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
);
__PACKAGE__->add_timestamps;

__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(settings => 'OpenQA::Schema::Result::JobSettings', 'job_id');
__PACKAGE__->belongs_to(worker => 'OpenQA::Schema::Result::Workers', 'worker_id');
__PACKAGE__->belongs_to(clone => 'OpenQA::Schema::Result::Jobs', 'clone_id', { join_type => 'left', on_delete => 'SET NULL' });
__PACKAGE__->might_have(origin => 'OpenQA::Schema::Result::Jobs', 'clone_id', { cascade_delete => 0 });
__PACKAGE__->has_many(jobs_assets => 'OpenQA::Schema::Result::JobsAssets', 'job_id');
__PACKAGE__->many_to_many(assets => 'jobs_assets', 'asset');
__PACKAGE__->has_many(children => 'OpenQA::Schema::Result::JobDependencies', 'parent_job_id');
__PACKAGE__->has_many(parents => 'OpenQA::Schema::Result::JobDependencies', 'child_job_id');
__PACKAGE__->has_many(modules => 'OpenQA::Schema::Result::JobModules', 'job_id');

__PACKAGE__->add_unique_constraint([qw/slug/]);

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    $sqlt_table->add_index(name => 'idx_jobs_state', fields => ['state']);
    $sqlt_table->add_index(name => 'idx_jobs_result', fields => ['result']);
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

sub _hashref {
    my $obj = shift;
    my @fields = @_;

    my %hashref = ();
    foreach my $field (@fields) {
        $hashref{$field} = $obj->$field;
    }

    return \%hashref;
}

sub to_hash {
    my ($job, %args) = @_;
    my $j = _hashref($job, qw/ id name priority state result worker_id clone_id retry_avbl t_started t_finished test/);
    $j->{settings} = { map { $_->key => $_->value } $job->settings->all() };
    if ($job->name && !$j->{settings}->{NAME}) {
        $j->{settings}->{NAME} = sprintf "%08d-%s", $job->id, $job->name;
    }
    if ($args{assets}) {
        for my $a ($job->jobs_assets->all()) {
            push @{$j->{assets}->{$a->asset->type}}, $a->asset->name;
        }
    }
    $j->{parents} = [];
    for my $p ($job->parents->all()) {
        push @{$j->{parents}}, $p->parent_job_id;
    }
    return $j;
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

    # Copied retry_avbl as default value if the input undefined
    $args->{retry_avbl} = $self->retry_avbl unless defined $args->{retry_avbl};
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

        my $new_job = $rsource->resultset->create(
            {
                test => $self->test,
                settings => \@new_settings,
                priority => $args->{prio} || $self->priority,
                jobs_assets => [ map { { asset => { id => $_->asset_id } } } $self->jobs_assets->all() ],
                retry_avbl => $args->{retry_avbl},
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
