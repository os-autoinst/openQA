# Copyright 2016-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::AMQP;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Mojo::IOLoop;
use OpenQA::Log qw(log_debug log_error);
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Events;
use Mojo::RabbitMQ::Client::Publisher;

my @job_events = qw(job_create job_delete job_cancel job_restart job_update_result job_done);
my @comment_events = qw(comment_create comment_update comment_delete);

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    $self->{app} = undef;
    $self->{config} = undef;
    $self->{client} = undef;
    $self->{channel} = undef;
    return $self;
}

sub register {
    my $self = shift;
    $self->{app} = shift;
    $self->{config} = $self->{app}->config;
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

sub log_event {
    my ($self, $event, $event_data) = @_;

    # use dot separators
    $event =~ s/_/\./;
    $event =~ s/_/\./;

    my $prefix = $self->{config}->{amqp}{topic_prefix};
    my $topic = $prefix ? $prefix . '.' . $event : $event;

    # separate function for tests
    $self->publish_amqp($topic, $event_data);
}

sub publish_amqp {
    my ($self, $topic, $event_data, $headers) = @_;
    $headers //= {};
    die "publish_amqp headers must be a hashref!" unless (ref($headers) eq 'HASH');

    log_debug("Sending AMQP event: $topic");
    my $publisher = Mojo::RabbitMQ::Client::Publisher->new(
        url => $self->{config}->{amqp}{url} . "?exchange=" . $self->{config}->{amqp}{exchange});

    # A hard reference to the publisher object needs to be kept until the event
    # has been published asynchronously, or it gets destroyed too early
    $publisher->publish_p($event_data, $headers, routing_key => $topic)->then(sub { log_debug "$topic published" })
      ->catch(sub ($error) { log_error "Publishing $topic failed: $error" })->finally(sub { undef $publisher });
}

sub on_job_event {
    my ($self, $args) = @_;

    my ($user_id, $connection_id, $event, $event_data) = @$args;
    my $jobs = $self->{app}->schema->resultset('Jobs');
    my $job = $jobs->find({id => $event_data->{id}});

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
    }
    my $job_settings = $job->settings_hash;
    for my $detail (qw(ISO HDD_1)) {
        $event_data->{$detail} //= $job_settings->{$detail} if ($job_settings->{$detail});
    }

    $self->log_event($event, $event_data);
}

sub on_comment_event {
    my ($self, $args) = @_;
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

    $self->log_event($event, $hash);
}

1;
