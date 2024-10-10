# Copyright 2015 SUSE LLC
#               2016-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::Workers;
use Mojo::Base 'DBIx::Class::Core', -signatures;

use DBIx::Class::Timestamps 'now';
use Try::Tiny;
use OpenQA::App;
use OpenQA::Log qw(log_error log_warning);
use OpenQA::WebSockets::Client;
use OpenQA::Constants qw(WORKER_API_COMMANDS DB_TIMESTAMP_ACCURACY);
use OpenQA::Jobs::Constants;
use Mojo::JSON qw(encode_json decode_json);
use DBI qw(:sql_types);

__PACKAGE__->table('workers');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'bigint',
        is_auto_increment => 1,
    },
    host => {
        data_type => 'text',
    },
    instance => {
        data_type => 'integer',
    },
    job_id => {
        data_type => 'bigint',
        is_foreign_key => 1,
        is_nullable => 1
    },
    t_seen => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    upload_progress => {
        data_type => 'jsonb',
        is_nullable => 1,
    },
    error => {
        data_type => 'text',
        is_nullable => 1,
    });
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(host instance)]);
# only one worker can work on a job
__PACKAGE__->add_unique_constraint([qw(job_id)]);
__PACKAGE__->belongs_to(job => 'OpenQA::Schema::Result::Jobs', 'job_id', {on_delete => 'SET NULL'});
__PACKAGE__->has_many(
    previous_jobs => 'OpenQA::Schema::Result::Jobs',
    'assigned_worker_id',
    {
        order_by => {-desc => 't_created'}});
__PACKAGE__->has_many(properties => 'OpenQA::Schema::Result::WorkerProperties', 'worker_id');

__PACKAGE__->inflate_column(
    upload_progress => {
        inflate => sub { decode_json(shift) },
        deflate => sub { encode_json(shift) },
    });

sub name {
    my ($self) = @_;
    return $self->host . ':' . $self->instance;
}

sub seen ($self, $options = {}) {
    my $data = {t_seen => now()};
    $data->{error} = $options->{error} if exists $options->{error};
    $self->update($data);
}

# update the properties of the worker with the specified capabilities
sub update_caps ($self, $workercaps) { $self->set_property(uc $_, $workercaps->{$_}) for keys %$workercaps }

sub get_property {
    my ($self, $key) = @_;

    # Optimized because this is a performance hot spot for the websocket server
    my $sth = $self->result_source->schema->storage->dbh->prepare(
        'SELECT value FROM worker_properties WHERE key = ? AND worker_id = ? LIMIT 1');
    $sth->bind_param(1, $key, SQL_CHAR);
    $sth->bind_param(2, $self->id, SQL_BIGINT);
    $sth->execute;
    my $r = $sth->fetchrow_arrayref;

    return $r ? $r->[0] : undef;
}

sub delete_properties {
    my ($self, $keys) = @_;

    return $self->properties->search({key => {-in => $keys}})->delete;
}

sub set_property {

    my ($self, $key, $val) = @_;
    return $self->properties->search({key => $key})->delete unless defined $val;

    my $r = $self->properties->find_or_new(
        {
            key => $key
        });

    if (!$r->in_storage) {
        $r->value($val);
        $r->insert;
    }
    else {
        $r->update({value => $val});
    }
}

sub dead {
    my ($self) = @_;

    return 1 unless my $t_seen = $self->t_seen;
    my $dt = DateTime->now(time_zone => 'UTC');
    $dt->subtract(seconds => OpenQA::App->singleton->config->{global}->{worker_timeout} - DB_TIMESTAMP_ACCURACY);
    $t_seen < $dt;
}

sub websocket_api_version ($self) {
    return $self->{_websocket_api_version} if exists $self->{_websocket_api_version};
    return $self->{_websocket_api_version} = $self->get_property('WEBSOCKET_API_VERSION');
}

sub check_class {
    my ($self, $class) = @_;

    unless ($self->{_worker_class_hash}) {
        for my $k (split /,/, ($self->get_property('WORKER_CLASS') || 'NONE')) {
            $self->{_worker_class_hash}->{$k} = 1;
        }
    }
    return defined $self->{_worker_class_hash}->{$class};
}

sub currentstep {
    my ($self) = @_;

    return unless ($self->job);
    my $r = $self->job->modules->find({result => 'running'}, {order_by => {-desc => 't_updated'}, rows => 1});
    $r->name if $r;
}

sub status {
    my ($self) = @_;

    return 'dead' if ($self->dead);
    return 'broken' if ($self->error);
    return 'running' if ($self->job);
    return 'idle';
}

sub unprepare_for_work {
    my $self = shift;

    $self->delete_properties([qw(JOBTOKEN WORKER_TMPDIR)]);
    $self->update({upload_progress => undef});

    return $self;
}

sub info ($self) {
    my $settings = {
        id => $self->id,
        host => $self->host,
        instance => $self->instance,
        status => $self->status,
        error => $self->error,
    };
    $settings->{properties} = {};
    for my $p ($self->properties->all) {
        $settings->{properties}->{$p->key} = $p->value;
    }
    # puts job id in status, otherwise is idle
    my $job = $self->job;
    if ($job) {
        $settings->{jobid} = $job->id;
        my $cs = $self->currentstep;
        $settings->{currentstep} = $cs if $cs;
    }
    $settings->{alive} = $settings->{connected} = $settings->{websocket} = $self->dead ? 0 : 1;
    return $settings;    # The keys "connected" and "websocket" are only provided for compatibility.
}

sub send_command {
    my ($self, %args) = @_;
    return undef if (!defined $args{command});

    if (!grep { $args{command} eq $_ } WORKER_API_COMMANDS) {
        my $msg = 'Trying to issue unknown command "%s" for worker "%s:%n"';
        log_error(sprintf($msg, $args{command}, $self->host, $self->instance));
        return undef;
    }

    try {
        OpenQA::App->singleton->emit_event(
            openqa_command_enqueue => {workerid => $self->id, command => $args{command}});
    };

    # prevent ws server querying itself (which would cause it to hang until the connection times out)
    if (OpenQA::WebSockets::Client::is_current_process_the_websocket_server) {
        return OpenQA::WebSockets::ws_send($self->id, $args{command}, $args{job_id}, undef);
    }

    my $client = OpenQA::WebSockets::Client->singleton;
    try { $client->send_msg($self->id, $args{command}, $args{job_id}) }
    catch {
        log_error(
            sprintf(
                'Failed dispatching message to websocket server over ipc for worker "%s:%n": %s',
                $self->host, $self->instance, $_
            ));
        return undef;
    };
    return 1;
}

sub unfinished_jobs {
    my ($self) = @_;

    return $self->previous_jobs->search({state => {-in => [OpenQA::Jobs::Constants::PENDING_STATES]}});
}

sub set_current_job {
    my ($self, $job) = @_;
    $self->update({job_id => $job->id});
}

sub reschedule_assigned_jobs {
    my ($self, $currently_assigned_jobs) = @_;
    $currently_assigned_jobs //= [$self->job, $self->unfinished_jobs];

    my %considered_jobs;
    for my $associated_job (@$currently_assigned_jobs) {
        next unless defined $associated_job;

        # prevent doing this twice for the same job ($current_job and @unfinished_jobs might overlap)
        my $job_id = $associated_job->id;
        next if exists $considered_jobs{$job_id};
        $considered_jobs{$job_id} = 1;

        # consider only assigned jobs here
        # note: Running jobs are only marked as incomplete on worker registration (and not here) because that
        #       operation can be quite costly.
        next if $associated_job->state ne ASSIGNED;

        # set associated job which was only assigned back to scheduled
        # note: Using a transaction here so we don't end up with an inconsistent state when an error occurs.
        try {
            $self->result_source->schema->txn_do(sub { $associated_job->reschedule_state });
        }
        catch {
            my $worker_id = $self->id;    # uncoverable statement
            log_warning("Unable to re-schedule job $job_id abandoned by worker $worker_id: $_"); # uncoverable statement
        };
    }
}

sub vnc_argument ($self) {
    my $hostname = $self->get_property('WORKER_HOSTNAME') || $self->host;
    my $instance = $self->instance + 5990;
    return "$hostname:$instance";
}

1;
