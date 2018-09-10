# Copyright (C) 2016 Red Hat
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

# An openQA plugin that emits fedmsgs for certain openQA events (by shadowing
# fedmsg internal events). See http://www.fedmsg.com for more on fedmsg.
# Currently quite specific to Fedora usage. Requires daemonize and
# fedmsg-logger.

package OpenQA::WebAPI::Plugin::Fedmsg;

use strict;
use warnings;

use parent 'Mojolicious::Plugin';
use IPC::Run;
use Cpanel::JSON::XS;
use Mojo::IOLoop;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;

# note: there is also job_cancel_by_settings, but that is quite an odd one;
# it basically does a search by the specified settings and cancels all
# jobs it finds. this is very difficult to translate into a fedmsg - classic
# or standardized - that'd be of any particular use to anyone; just saying
# 'some jobs were cancelled and here's the search that found them' isn't
# much good. You could try to duplicate the search and list all pending job
# IDs that are found, but there's a race there, and I don't think anything
# guarantees that we'd get to find the jobs before they got cancelled; trying
# to find ones that were *just* cancelled seems like a thankless task.
my @job_events     = qw(job_create job_delete job_cancel job_duplicate job_restart job_update_result job_done);
my @comment_events = qw(comment_create comment_update comment_delete);

sub register {
    my ($self, $app) = @_;
    my $reactor = Mojo::IOLoop->singleton;

    # register for events
    for my $e (@job_events) {
        $reactor->on("openqa_$e" => sub { shift; $self->on_job_event($app, @_) });
    }
    for my $e (@comment_events) {
        $reactor->on("openqa_$e" => sub { shift; $self->on_comment_event($app, @_) });
    }
}

sub log_event {
    my ($event, $event_data) = @_;

    # we're going to explicitly pass this as the modname
    $event =~ s/^openqa_//;
    # fedmsg uses dot separators
    $event =~ s/_/\./g;

    # convert data to JSON, with reliable key ordering (helps the tests)
    $event_data = Cpanel::JSON::XS->new->canonical(1)->allow_blessed(1)->encode($event_data);

    OpenQA::Utils::log_debug("Sending fedmsg for $event");

    # do you want to write perl bindings for fedmsg? no? me either.
    # FIXME: should be some way for plugins to have configuration and then
    # cert-prefix could be configurable, for now we hard code it
    # we use IPC::Run rather than system() as it's easier to mock for testing,
    # and we daemonize so we don't block until the message is sent (which can
    # cause problems when sending hundreds of messages on ISO post)
    my @command = (
        "/usr/sbin/daemonize", "/usr/bin/fedmsg-logger", "--cert-prefix=openqa", "--modname=openqa",
        "--topic=$event",      "--json-input",           "--message=$event_data"
    );
    my ($stdin, $stderr, $output) = (undef, undef, undef);
    IPC::Run::run(\@command, \$stdin, \$output, \$stderr);
}

sub log_event_ci_standard {
    # this is for emitting messages in the standardized format for
    # Factory 2.0 CI systems
    my ($event, $job, $baseurl) = @_;
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
        if (grep { $job->result eq $_ } OpenQA::Schema::Result::Jobs::INCOMPLETE_RESULTS) {
            $stdevent = 'error';
        }
        else {
            $stdevent = 'complete';
        }
    }
    else {
        return;
    }

    # next, get the 'artifact' (type of thing we tested)
    my $artifact;
    my $artifact_id;
    my $artifact_issuer;
    my $artifact_release;
    my $build = $job->BUILD;
    if ($build =~ /^Fedora/) {
        $artifact        = 'productmd-compose';
        $artifact_id     = $build;
        $artifact_issuer = 'releng';
        $artifact_issuer = 'respins-sig' if ($build =~ /^FedoraRespin/);
    }
    elsif ($build =~ /^Update-/) {
        $artifact    = 'fedora-update';
        $artifact_id = $build;
        $artifact_id =~ s/^Update-//;
        $artifact_release = $job->VERSION;
        # FIXME: this info is in Bodhi but not known to openQA ATM
        $artifact_issuer = 'unknown';
    }
    else {
        # unhandled artifact type
        return;
    }

    # finally, construct the message content
    my %msg_data = (
        headers => {
            type => $artifact,
            id   => $artifact_id,
        },
        body => {
            ci => {
                name  => 'Fedora openQA',
                team  => 'Fedora QA',
                url   => $baseurl,
                irc   => '#fedora-qa',
                email => 'qa-devel@lists.fedoraproject.org',
            },
            run => {
                url => "$baseurl/tests/$job_id",
                log => "$baseurl/tests/$job_id/file/autoinst-log.txt",
                id  => $job_id,
            },
            artifact => {
                type   => $artifact,
                id     => $artifact_id,
                issuer => $artifact_issuer,
                # FIXME: we're gonna need to define more useful fields
                # in the spec for artifacts besides brew/koji builds,
                # but for now let's just do the obvious ones
            },
            # test identifier: test name plus scenario keys
            type => join(' ', $job->TEST, $job->MACHINE, $job->FLAVOR, $job->ARCH),
            # openQA tests are pretty much always validation
            category => 'validation',
        },
    );

    # add keys that don't exist in all cases to the message
    if ($stdevent eq 'complete') {
        $msg_data{body}{status} = $job->result;
        $msg_data{body}{status} = 'info' if $job->result eq 'softfailed';
    }
    elsif ($stdevent eq 'error') {
        $msg_data{body}{reason} = $job->result;
    }
    elsif ($stdevent eq 'queued') {
        # this is a hint to consumers that the job probably went away
        # if they don't get a 'complete' or 'error' in 4 hours
        # FIXME: we should set this as 2 hours on 'running', but we
        # can't emit running ATM...
        $msg_data{body}{lifetime} = 240;
    }
    $msg_data{body}{run}{clone_of} = $clone_of if ($clone_of);

    $msg_data{body}{artifact}{release} = $artifact_release if ($artifact_release);

    $msg_data{body}{artifact}{iso} = $job->settings_hash->{ISO} if ($job->settings_hash->{ISO});
    # FIXME: hdd_2?
    $msg_data{body}{artifact}{hdd_1} = $job->settings_hash->{HDD_1} if ($job->settings_hash->{HDD_1});

    # convert data to JSON, with reliable key ordering (helps the tests)
    my $msg_json = Cpanel::JSON::XS->new->canonical(1)->allow_blessed(1)->encode(\%msg_data);

    # create the topic
    my $topic = "$artifact.test.$stdevent";

    # finally, send the message
    OpenQA::Utils::log_debug("Sending standardized fedmsg for $event");
    my @command = (
        "/usr/sbin/daemonize", "/usr/bin/fedmsg-logger", "--cert-prefix=ci", "--modname=ci",
        "--topic=$topic",      "--json-input",           "--message=$msg_json"
    );
    my ($stdin, $stderr, $output) = (undef, undef, undef);
    IPC::Run::run(\@command, \$stdin, \$output, \$stderr);
}

# when we get an event, convert it to fedmsg format and send it

sub on_job_event {
    my ($self, $app, $args) = @_;
    my ($user_id, $connection_id, $event, $event_data) = @$args;
    # find count of pending jobs for the same build
    # this is so we can tell when all tests for a build are done
    my $job = $app->db->resultset('Jobs')->find({id => $event_data->{id}});
    # Get app baseurl, as the ci_standard logger needs it
    my $baseurl = $app->config->{global}->{base_url} || "http://UNKNOWN";
    my $build = $job->BUILD;
    $event_data->{remaining} = $app->db->resultset('Jobs')->search(
        {
            'me.BUILD' => $build,
            state      => [OpenQA::Jobs::Constants::PENDING_STATES],
        })->count;
    # add various useful properties for consumers if not there already
    $event_data->{BUILD}   //= $build;
    $event_data->{TEST}    //= $job->TEST;
    $event_data->{ARCH}    //= $job->ARCH;
    $event_data->{MACHINE} //= $job->MACHINE;
    $event_data->{FLAVOR}  //= $job->FLAVOR;
    $event_data->{ISO}     //= $job->settings_hash->{ISO} if ($job->settings_hash->{ISO});
    $event_data->{HDD_1}   //= $job->settings_hash->{HDD_1} if ($job->settings_hash->{HDD_1});

    log_event($event, $event_data);
    log_event_ci_standard($event, $job, $baseurl);
}

sub on_comment_event {
    my ($self, $app, $args) = @_;
    my ($user_id, $connection_id, $event, $event_data) = @$args;
    my $hash;

    # find comment in database. on comment deletion, the mojo event
    # is emitted *before* the comment is actually deleted, so this
    # should still work
    my $comment = $app->db->resultset('Comments')->find($event_data->{id});
    return unless $comment;

    # just send the hash already used for JSON representation
    $hash = $comment->hash;
    # also include comment id, job_id, and group_id
    $hash->{id}       = $comment->id;
    $hash->{job_id}   = $comment->job_id;
    $hash->{group_id} = $comment->group_id;

    log_event($event, $hash);
}

1;
