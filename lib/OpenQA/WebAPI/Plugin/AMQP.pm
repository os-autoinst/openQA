# Copyright 2016-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::AMQP;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use OpenQA::Log qw(log_debug log_info log_error);
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Events;
use Mojo::IOLoop;
use Mojo::RabbitMQ::Client::Publisher;
use Mojo::URL;
use Scalar::Util qw(looks_like_number);

my @job_events = qw(job_create job_delete job_cancel job_restart job_update_result job_done);
my @comment_events = qw(comment_create comment_update comment_delete);

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    $self->{app} = undef;
    $self->{config} = undef;
    $self->{client} = undef;
    $self->{channel} = undef;
    return $self;
}

sub register ($self, $app, @args) {
    $self->{app} = $app;
    $self->{config} = $app->config;
    my $config = $self->{config}->{amqp};
    $config->{enabled} = 1;    # Needed for reloading the plugin later in the forked process
    Mojo::IOLoop->singleton->next_tick(
        sub {
            # register for events
            for my $e (@job_events) {
                OpenQA::Events->singleton->on("openqa_$e" => sub { shift; $self->on_job_event(@_) });
            }
            for my $e (@comment_events) {
                OpenQA::Events->singleton->on("openqa_$e" => sub { shift; $self->on_comment_event(@_) });
            }
        });
}

sub log_event ($self, $event, $event_data) {

    # use dot separators
    $event =~ s/_/\./;
    $event =~ s/_/\./;

    my $prefix = $self->{config}->{amqp}{topic_prefix};
    $self->publish_amqp($prefix ? "$prefix.$event" : $event, $event_data);
}

sub publish_amqp ($self, $topic, $event_data, $headers = {}, $remaining_attempts = undef, $retry_delay = undef) {
    return log_error "Publishing $topic failed: headers are not a hashref" unless ref $headers eq 'HASH';

    # create publisher and keep reference to avoid early destruction
    log_debug("Sending AMQP event: $topic");
    my $config = $self->{config}->{amqp};
    my $unsanitized_url = Mojo::URL->new($config->{url});
    $unsanitized_url->query({exchange => $config->{exchange}});
    # append optional parameters
    $unsanitized_url->query([cacertfile => $config->{cacertfile}]) if ($config->{cacertfile});
    $unsanitized_url->query([certfile => $config->{certfile}]) if ($config->{certfile});
    $unsanitized_url->query([keyfile => $config->{keyfile}]) if ($config->{keyfile});
    my $url = $unsanitized_url->clone;
    $unsanitized_url = $unsanitized_url->to_unsafe_string;
    my $publisher = Mojo::RabbitMQ::Client::Publisher->new(url => $unsanitized_url);
    log_debug("AMQP URL: $url");

    $remaining_attempts //= $config->{publish_attempts};
    $retry_delay //= $config->{publish_retry_delay};
    $publisher->publish_p($event_data, $headers, routing_key => $topic)->then(
        sub {
            log_debug "$topic published";
            OpenQA::Events->singleton->emit('amqp_handled');
        }
    )->catch(
        sub ($error) {
            my $left = looks_like_number $remaining_attempts && $remaining_attempts > 1 ? $remaining_attempts - 1 : 0;
            my $delay = $retry_delay * $config->{publish_retry_delay_factor};
            my ($event_id, $job_id) = ($event_data->{id} // 'none', $event_data->{job_id});
            my $additional_info = $job_id ? ", job ID: $job_id" : '';
            my $log_msg = "Publishing $topic failed: $error (event ID: $event_id$additional_info, $left attempts left)";
            my $retry_function = sub ($loop) { $self->publish_amqp($topic, $event_data, $headers, $left, $delay) };
            if ($left) {
                log_info $log_msg;
                Mojo::IOLoop->timer($retry_delay => $retry_function);
                return;
            }
            OpenQA::Events->singleton->emit('amqp_handled');
            return log_error $log_msg;
        })->finally(sub { undef $publisher });
}

sub on_job_event ($self, $args) {
    my ($user_id, $connection_id, $event, $event_data) = @$args;
    my $jobs = $self->{app}->schema->resultset('Jobs');
    return undef unless my $job = $jobs->find({id => $event_data->{id}});

    # find count of pending jobs for the same build to know whether all tests for a build are done
    $event_data->{remaining} = $jobs->search(
        {
            'me.BUILD' => $job->BUILD,
            state => [OpenQA::Jobs::Constants::PENDING_STATES],
        })->count;

    # add various useful properties for consumers if not there already
    for my $detail (qw(group_id BUILD TEST ARCH MACHINE FLAVOR)) {
        $event_data->{$detail} //= $job->$detail;
    }
    if ($job->state eq OpenQA::Jobs::Constants::DONE) {
        my $bugref = $job->bugref;
        if ($event_data->{bugref} = $bugref) {
            $event_data->{bugurl} = OpenQA::Utils::bugurl($bugref);
        }
        $event_data->{failedmodules} = $job->failed_modules;
    }
    my $job_settings = $job->settings_hash;
    for my $detail (qw(ISO HDD_1)) {
        $event_data->{$detail} //= $job_settings->{$detail} if ($job_settings->{$detail});
    }

    $self->log_event($event, $event_data);
}

sub on_comment_event ($self, $args) {
    my ($comment_id, $connection_id, $event, $event_data) = @$args;

    # find comment in database
    my $comment = $self->{app}->schema->resultset('Comments')->find($event_data->{id});
    return unless $comment;

    # just send the hash already used for JSON representation
    my $hash = $comment->hash;
    # also include comment id, job_id, and group_id
    $hash->{id} = $comment->id;
    $hash->{job_id} = $comment->job_id;
    $hash->{group_id} = $comment->group_id;
    $hash->{parent_group_id} = $comment->parent_group_id;
    if (my $id = $event_data->{taken_over_from_job_id}) {
        $hash->{taken_over_from_job_id} = $id;
        $hash->{bugref} = $comment->bugref;
    }

    $self->log_event($event, $hash);
}

1;
