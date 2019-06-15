# Copyright (C) 2016-2019 SUSE LLC
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

package OpenQA::WebAPI::Plugin::AMQP;
use Mojo::Base 'Mojolicious::Plugin';

use Mojo::JSON;    # booleans
use Cpanel::JSON::XS ();
use Mojo::IOLoop;
use OpenQA::Utils;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Events;
use Mojo::RabbitMQ::Client::Publisher;
use POSIX qw(strftime);

my @job_events     = qw(job_create job_delete job_cancel job_duplicate job_restart job_update_result job_done);
my @comment_events = qw(comment_create comment_update comment_delete);

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);
    $self->{app}     = undef;
    $self->{config}  = undef;
    $self->{client}  = undef;
    $self->{channel} = undef;
    return $self;
}

sub register {
    my $self = shift;
    $self->{app}    = shift;
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

    my $topic = $self->{config}->{amqp}{topic_prefix} . '.' . $event;

    # convert data to JSON, with reliable key ordering (helps the tests)
    $event_data = Cpanel::JSON::XS->new->canonical(1)->allow_blessed(1)->ascii(1)->encode($event_data);

    # seperate function for tests
    $self->publish_amqp($topic, $event_data);
}

sub log_event_fedora_ci_messages {
    # this is for emitting messages in the "CI Messages" format:
    # https://pagure.io/fedora-ci/messages
    # This is a Fedora/Red Hat-ish thing in a way, but in theory
    # anyone could adopt it
    my ($self, $event, $job, $baseurl) = @_;
    my $stdevent;
    my $clone_of;
    my $job_id;
    # first, get the standard 'state' (from 'queued', 'running',
    # 'complete', 'error'; we cannot do 'running' at present
    if ($event eq 'openqa_job_create') {
        $stdevent = 'queued';
        $job_id   = $job->id;
    }
    elsif ($event eq 'openqa_job_restart' || $event eq 'openqa_job_duplicate') {
        $stdevent = 'queued';
        $clone_of = $job->id;
        $job_id   = $job->clone_id;
    }
    elsif ($event eq 'openqa_job_cancel') {
        $stdevent = 'error';
        $job_id   = $job->id;
    }
    elsif ($event eq 'openqa_job_done') {
        $job_id = $job->id;
        # lifecycle note: any job cancelled directly via the web API will
        # see both job_cancel and job_done with result USER_CANCELLED, so
        # we emit duplicate standardized fedmsgs in this case. This is
        # kinda unavoidable, though, as it's possible for a job to wind up
        # USER_CANCELLED *without* an openqa_job_cancel event happening,
        # so we can't just throw away all openqa_job_done USER_CANCELLED
        # events...
        $stdevent = (grep { $job->result eq $_ } INCOMPLETE_RESULTS) ? 'error' : 'complete';
    }
    else {
        return undef;
    }

    # we need this for the system dict; it should be the release of
    # the system-under-test (the VM in which the test runs) at the
    # *start* of the test, I think. We're trying to capture info about
    # the environment in which the test runs
    my $sysrelease = $job->VERSION;
    my $hdd1;
    my $bootfrom;
    $hdd1     = $job->settings_hash->{HDD_1}    if ($job->settings_hash->{HDD_1});
    $bootfrom = $job->settings_hash->{BOOTFROM} if ($job->settings_hash->{BOOTFROM});
    if ($hdd1 && $bootfrom) {
        $sysrelease = $1 if ($hdd1 =~ /disk_f(\d+)/ && $bootfrom eq 'c');
    }

    # next, get the 'artifact' (type of thing we tested)
    my $artifact;
    my $artifact_id;
    my $artifact_release;
    my $compose_type;
    my $test_namespace;
    # current date/time in ISO 8601 format
    my $generated_at = strftime("%Y-%m-%dT%H:%M:%S", gmtime()) . 'Z';

    # this is used as a 'pipeline ID', see
    # https://pagure.io/fedora-ci/messages/blob/master/f/schemas/pipeline.yaml
    my $pipeid = join('.', "openqa", $job->BUILD, $job->TEST, $job->MACHINE, $job->FLAVOR, $job->ARCH);

    my $build = $job->BUILD;
    if ($build =~ /^Fedora/) {
        $artifact       = 'productmd-compose';
        $artifact_id    = $build;
        $compose_type   = 'production';
        $compose_type   = 'nightly' if ($build =~ /\.n\./);
        $compose_type   = 'test' if ($build =~ /\.t\./);
        $test_namespace = 'compose';
    }
    elsif ($build =~ /^Update-FEDORA/) {
        $artifact    = 'fedora-update';
        $artifact_id = $build;
        $artifact_id =~ s/^Update-//;
        $artifact_release = $job->VERSION;
        $test_namespace   = 'update';
    }
    else {
        # unhandled artifact type
        return undef;
    }

    # finally, construct the message content
    my %msg_data = (
        contact => {
            name  => 'Fedora openQA',
            team  => 'Fedora QA',
            url   => $baseurl,
            docs  => 'https://fedoraproject.org/wiki/OpenQA',
            irc   => '#fedora-qa',
            email => 'qa-devel@lists.fedoraproject.org',
        },
        run => {
            url => "$baseurl/tests/$job_id",
            log => "$baseurl/tests/$job_id/file/autoinst-log.txt",
            id  => $job_id,
        },
        artifact => {
            type => $artifact,
            id   => $artifact_id,
        },
        pipeline => {
            # per https://pagure.io/fedora-ci/messages/issue/61 this
            # is meant to be unique per test scenario *and* artifact,
            # so we construct it out of BUILD and the scenario keys.
            # 'name' is supposed to be a 'human readable name', well,
            # this is human readable, so we'll just use it twice
            id   => $pipeid,
            name => $pipeid,
        },
        test => {
            # openQA tests are pretty much always validation
            category => 'validation',
            # test identifier: test name plus scenario keys
            type      => join(' ', $job->TEST, $job->MACHINE, $job->FLAVOR, $job->ARCH),
            namespace => $test_namespace,
        },
        system => {
            # it's interesting whether we should record info on the
            # *worker host itself* or the *SUT* (the VM run on top of
            # the worker host environment) here...on the whole I think
            # SUT is more in line with expectations, so let's do that
            os => "fedora-${sysrelease}",
            # openqa provisions itself...we *could* I guess set this
            # to 'createhdds' if we booted a disk image, but ehhhh
            provider     => 'openqa',
            architecture => $job->ARCH,
            variant      => $job->settings_hash->{SUBVARIANT},
        },
        generated_at => $generated_at,
        version      => "0.2.1",
    );

    # add keys that don't exist in all cases to the message
    if ($stdevent eq 'complete') {
        $msg_data{test}{result} = $job->result;
        $msg_data{test}{result} = 'info' if $job->result eq 'softfailed';
    }
    elsif ($stdevent eq 'error') {
        $msg_data{error} = {};
        $msg_data{error}{reason} = $job->result;
    }
    elsif ($stdevent eq 'queued') {
        # this is a hint to consumers that the job probably went away
        # if they don't get a 'complete' or 'error' in 4 hours
        # FIXME: we should set this as 2 hours on 'running', but we
        # can't emit running because there is no internal event for
        # it, there is no job_running event or anything like it -
        # this is part of https://progress.opensuse.org/issues/31069
        $msg_data{test}{lifetime} = 240;
    }
    $msg_data{run}{clone_of} = $clone_of if ($clone_of);

    $msg_data{artifact}{release} = $artifact_release if ($artifact_release);

    $msg_data{artifact}{compose_type} = $compose_type if ($compose_type);

    $msg_data{artifact}{iso} = $job->settings_hash->{ISO} if ($job->settings_hash->{ISO});
    # 9 hard disks ought to be enough for anyone
    for my $i (1 .. 9) {
        $msg_data{artifact}{"hdd_$i"} = $job->settings_hash->{"HDD_$i"} if ($job->settings_hash->{"HDD_$i"});
    }

    # convert data to JSON, with reliable key ordering (helps the tests)
    my $msg_json = Cpanel::JSON::XS->new->canonical(1)->allow_blessed(1)->encode(\%msg_data);

    # create the topic
    my $topic = "ci.$artifact.test.$stdevent";

    # finally, send the message
    log_debug("Sending CI Messages AMQP message for $event");
    $self->publish_amqp($topic, $msg_json);
}

sub publish_amqp {
    my ($self, $topic, $event_data) = @_;

    log_debug("Sending AMQP event: $topic");
    my $publisher = Mojo::RabbitMQ::Client::Publisher->new(
        url => $self->{config}->{amqp}{url} . "?exchange=" . $self->{config}->{amqp}{exchange});

    # A hard reference to the publisher object needs to be kept until the event
    # has been published asynchronously, or it gets destroyed too early
    $publisher->publish_p($event_data, routing_key => $topic)->then(
        sub {
            log_debug "$topic published";
        }
    )->catch(
        sub {
            die "Publishing $topic failed";
        })->finally(sub { undef $publisher });
}

sub on_job_event {
    my ($self, $args) = @_;

    my ($user_id, $connection_id, $event, $event_data) = @$args;
    my $jobs = $self->{app}->schema->resultset('Jobs');
    my $job  = $jobs->find({id => $event_data->{id}});

    # find count of pending jobs for the same build to know whether all tests for a build are done
    $event_data->{remaining} = $jobs->search(
        {
            'me.BUILD' => $job->BUILD,
            state      => [OpenQA::Jobs::Constants::PENDING_STATES],
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
    if ($self->{config}->{amqp}{fedora_ci_messages}) {
        my $baseurl = $self->{config}->{global}->{base_url} || "http://UNKNOWN";
        $self->log_event_fedora_ci_messages($event, $job, $baseurl);
    }
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
    $hash->{id}              = $comment->id;
    $hash->{job_id}          = $comment->job_id;
    $hash->{group_id}        = $comment->group_id;
    $hash->{parent_group_id} = $comment->parent_group_id;

    $self->log_event($event, $hash);
}

1;
