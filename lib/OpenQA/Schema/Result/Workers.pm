# Copyright 2015 SUSE LLC
#               2016-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::Workers;
use Mojo::Base 'DBIx::Class::Core', -signatures;

use DBIx::Class::Timestamps 'now';
use Feature::Compat::Try;
use OpenQA::App;
use OpenQA::Log qw(log_error log_warning log_info);
use OpenQA::WebSockets::Client;
use OpenQA::Constants qw(WORKER_API_COMMANDS DB_TIMESTAMP_ACCURACY VNC_PORT);
use OpenQA::Jobs::Constants;
use OpenQA::Utils 'parse_duration';
use OpenQA::WorkerReservation
  qw(RESERVATION_PROPERTIES RESERVATION_TIMESTAMP_FORMAT reservation_active reservation_error);
use Mojo::JSON qw(encode_json decode_json);
use List::Util qw(any);
use Time::Seconds;
use DBI qw(:sql_types);

use constant WS_SERVER_GRACE_PERIOD => $ENV{OPENQA_WEB_SOCKETS_GRACE_PERIOD} // (ONE_MINUTE * 5);

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

sub name ($self) {
    return $self->host . ':' . $self->instance;
}

sub seen ($self, $options = {}) {
    my $data = {t_seen => now()};
    $data->{error} = $options->{error} if exists $options->{error};
    $self->update($data);
}

# update the properties of the worker with the specified capabilities
sub update_caps ($self, $workercaps) { $self->set_property(uc $_, $workercaps->{$_}) for keys %$workercaps }

sub get_property ($self, $key) {
    # Optimized because this is a performance hot spot for the websocket server
    my $sth = $self->result_source->schema->storage->dbh->prepare(
        'SELECT value FROM worker_properties WHERE key = ? AND worker_id = ? LIMIT 1');
    $sth->bind_param(1, $key, SQL_CHAR);
    $sth->bind_param(2, $self->id, SQL_BIGINT);
    $sth->execute;
    my $r = $sth->fetchrow_arrayref;

    return $r ? $r->[0] : undef;
}

sub delete_properties ($self, $keys) {
    return $self->properties->search({key => {-in => $keys}})->delete;
}

sub set_property ($self, $key, $val) {
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

sub _reservation_properties ($self) {
    return {map { $_->key => $_->value } $self->properties->search({key => {-in => [RESERVATION_PROPERTIES]}})->all};
}

sub is_reserved ($self) {
    my $properties = $self->_reservation_properties;
    return reservation_active($properties->{RESERVED_BY_ID}, $properties->{RESERVED_T_EXPIRES});
}

sub _username_for ($self, $user_id) {
    my $user = $self->result_source->schema->resultset('Users')->find($user_id);
    return $user ? $user->username : 'unknown';
}

sub _reserved_by_name ($self) { $self->_username_for($self->_reservation_properties->{RESERVED_BY_ID}) }

sub _iso_timestamp ($epoch) {
    $epoch ? DateTime->from_epoch(epoch => $epoch, time_zone => 'UTC')->strftime(RESERVATION_TIMESTAMP_FORMAT) : undef;
}

sub _reservation_info ($self, $properties) {
    {
        user => $self->_username_for($properties->{RESERVED_BY_ID}),
        comment => $properties->{RESERVED_COMMENT},
        t_created => _iso_timestamp($properties->{RESERVED_T_CREATED}),
        t_expires => _iso_timestamp($properties->{RESERVED_T_EXPIRES}),
    };
}

# the active reservation in the form exposed via the API, undef if the worker is not reserved;
# expired reservations are reported as absent so that stale properties are never observable
sub reservation ($self) {
    my $properties = $self->_reservation_properties;
    return undef unless reservation_active($properties->{RESERVED_BY_ID}, $properties->{RESERVED_T_EXPIRES});
    return $self->_reservation_info($properties);
}

# returns the duration in seconds a reservation may last for, 0 meaning unlimited
sub _reservation_duration ($duration, $is_admin) {
    my $config = OpenQA::App->singleton->config->{worker_reservation};
    my $seconds = defined $duration ? parse_duration($duration) : $config->{default_duration};
    die reservation_error(invalid => "Invalid duration format '$duration'") unless defined $seconds;
    die reservation_error(forbidden => 'Indefinite reservations are only allowed for admins')
      if $seconds == 0 && !$is_admin;
    my $limit = $is_admin ? $config->{admin_max_duration} : $config->{max_duration};
    die reservation_error(invalid => "Duration of ${seconds}s exceeds the maximum of ${limit}s")
      if $limit > 0 && $seconds > $limit;
    return $seconds;
}

sub reserve ($self, $user, $comment = undef, $duration = undef, $force = 0) {
    my $is_admin = $user->is_admin;
    die reservation_error(forbidden => 'Insufficient permissions to reserve a worker')
      unless $is_admin || $user->is_operator;
    die reservation_error(invalid => 'A comment is required for worker reservation')
      if OpenQA::App->singleton->config->{worker_reservation}->{comment_required}
      && (!defined $comment || $comment =~ /^\s*$/);
    my $seconds = _reservation_duration($duration, $is_admin);

    # the conflict check and all property writes must be atomic, a partially written reservation
    # without expiry would keep the worker reserved forever
    my $now = time;
    $self->result_source->schema->txn_do(
        sub {
            die reservation_error(conflict => 'Worker is already reserved by ' . $self->_reserved_by_name)
              if $self->is_reserved && !($force && $is_admin);
            $self->set_property(RESERVED_BY_ID => $user->id);
            $self->set_property(RESERVED_COMMENT => $comment);
            $self->set_property(RESERVED_T_CREATED => $now);
            $self->set_property(RESERVED_T_EXPIRES => $seconds == 0 ? 0 : $now + $seconds);
        });
    return $self;
}

sub release ($self, $user) {
    die reservation_error(invalid => 'Worker is not reserved') unless $self->is_reserved;
    die reservation_error(
        forbidden => 'Insufficient permissions to release reservation owned by ' . $self->_reserved_by_name)
      unless $user->is_admin || $self->_reservation_properties->{RESERVED_BY_ID} == $user->id;
    $self->delete_properties([RESERVATION_PROPERTIES]);
    return $self;
}

sub dead ($self) {
    return 1 unless my $t_seen = $self->t_seen;
    my $dt = DateTime->now(time_zone => 'UTC');
    $dt->subtract(seconds => OpenQA::App->singleton->config->{global}->{worker_timeout} - DB_TIMESTAMP_ACCURACY);
    $t_seen < $dt;
}

sub websocket_api_version ($self) {
    my $v = $self->{_websocket_api_version} // $self->get_property('WEBSOCKET_API_VERSION');
    return $self->{_websocket_api_version} = $v if $v;
    return undef;
}

sub check_class ($self, $class) {
    unless ($self->{_worker_class_hash}) {
        for my $k (split /,/, ($self->get_property('WORKER_CLASS') || 'NONE')) {
            $self->{_worker_class_hash}->{$k} = 1;
        }
    }
    return defined $self->{_worker_class_hash}->{$class};
}

sub currentstep ($self) {
    return unless ($self->job);
    my $r = $self->job->modules->find({result => 'running'}, {order_by => {-desc => 't_updated'}, rows => 1});
    $r->name if $r;
}

sub is_free ($self) {
    return !$self->job_id && !defined $self->error;
}

# $is_reserved can be passed by callers which already know the reservation state to save queries
sub status ($self, $is_reserved = undef) {
    return 'dead' if ($self->dead);
    return 'broken' if ($self->error);
    return 'running' if ($self->job);
    return 'reserved' if ($is_reserved // $self->is_reserved);
    return 'idle';
}

sub unprepare_for_work ($self) {
    $self->delete_properties([qw(JOBTOKEN WORKER_TMPDIR)]);
    $self->update({upload_progress => undef});

    return $self;
}

sub info ($self) {
    my %properties = map { $_->key => $_->value } $self->properties->all;
    my $reserved = reservation_active($properties{RESERVED_BY_ID}, $properties{RESERVED_T_EXPIRES});
    my $settings = {
        id => $self->id,
        host => $self->host,
        instance => $self->instance,
        status => $self->status($reserved),
        error => $self->error,
    };
    $settings->{reservation} = $self->_reservation_info(\%properties) if $reserved;
    # the reservation is exposed in structured form only, not as raw internal properties
    $settings->{properties} = {map { $_ => $properties{$_} } grep { !/^RESERVED_/ } keys %properties};
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

sub send_command ($self, %args) {
    return undef unless defined(my $command = $args{command});

    if (!any { $command eq $_ } WORKER_API_COMMANDS) {
        my $msg = 'Trying to issue unknown command "%s" for worker "%s:%n"';
        log_error(sprintf $msg, $command, $self->host, $self->instance);
        return undef;
    }

    try {
        OpenQA::App->singleton->emit_event(openqa_command_enqueue => {workerid => $self->id, command => $command});
    }
    catch ($e) { }

    # prevent ws server querying itself (which would cause it to hang until the connection times out)
    if (OpenQA::WebSockets::Client::is_current_process_the_websocket_server) {
        return OpenQA::WebSockets::ws_send($self->id, $command, $args{job_id}, undef);
    }

    my $client = OpenQA::WebSockets::Client->singleton;
    state $first_error_time = undef;
    try { $client->send_msg($self->id, $command, $args{job_id}); $first_error_time = undef; }
    catch ($e) {
        my $msg = sprintf 'Failed to send command "%s" to websocket server (regarding worker "%s:%n"): %s',
          $command, $self->host, $self->instance, $e;
        my $error_time = time;
        my $within_grace_period = !$first_error_time || ($error_time - $first_error_time) <= WS_SERVER_GRACE_PERIOD;
        $first_error_time //= $error_time;
        $within_grace_period ? log_info($msg) : log_error($msg);
        return undef;
    }
    return 1;
}

sub unfinished_jobs ($self) {
    return $self->previous_jobs->search({state => {-in => [OpenQA::Jobs::Constants::PENDING_STATES]}});
}

sub set_current_job ($self, $job) {
    $self->update({job_id => $job->id});
}

sub reschedule_assigned_jobs ($self, $currently_assigned_jobs = undef) {
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
        catch ($e) {
            my $worker_id = $self->id;    # uncoverable statement
            log_warning("Unable to re-schedule job $job_id abandoned by worker $worker_id: $e"); # uncoverable statement
        }
    }
}

sub vnc_argument ($self) {
    my $hostname = $self->get_property('WORKER_HOSTNAME') || $self->host;
    my $instance = $self->instance + VNC_PORT;
    return "$hostname:$instance";
}

1;
