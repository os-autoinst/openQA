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

package OpenQA::WebAPI::Plugin::Fedmsg;

use strict;
use warnings;

use parent qw/Mojolicious::Plugin/;
use IPC::Run;
use JSON;
use Mojo::IOLoop;
use OpenQA::Schema::Result::Jobs;

my @job_events = qw/job_create job_delete job_cancel job_duplicate job_restart jobs_restart job_update_result job_done/;
my @comment_events = qw/user_new_comment user_update_comment user_delete_comment/;

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

    # convert data to JSON, with reliable key ordering (helps the tests)
    $event_data = to_json($event_data, {canonical => 1, allow_blessed => 1});

    OpenQA::Utils::log_debug("Sending fedmsg for $event");

    # do you want to write perl bindings for fedmsg? no? me either.
    # FIXME: should be some way for plugins to have configuration and then
    # cert-prefix could be configurable, for now we hard code it
    # we use IPC::Run rather than system() as it's easier to mock for testing
    my @command = (
        "fedmsg-logger", "--cert-prefix=openqa", "--modname=openqa", "--topic=$event",
        "--json-input",  "--message=$event_data"
    );
    my ($stdin, $stderr, $output) = (undef, undef, undef);
    IPC::Run::run(\@command, \$stdin, \$output, \$stderr);
}

# when we get an event, convert it to fedmsg format and send it

sub on_job_event {
    my ($self, $app, $args) = @_;
    my ($user_id, $connection_id, $event, $event_data) = @$args;
    # we're going to explicitly pass this as the modname
    $event =~ s/^openqa_//;
    # fedmsg uses dot separators
    $event =~ s/_/\./;
    # find count of pending jobs for the same build
    # this is so we can tell when all tests for a build are done
    my $job = $app->db->resultset('Jobs')->find({id => $event_data->{id}});
    my $build = $job->BUILD;
    $event_data->{remaining} = $app->db->resultset('Jobs')->search(
        {
            'me.BUILD' => $build,
            state      => [OpenQA::Schema::Result::Jobs::PENDING_STATES],
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
}

sub on_comment_event {
    my ($self, $app, $args) = @_;
    my ($comment_id, $connection_id, $event, $event_data) = @$args;

    # find comment in database
    my $comment = $app->db->resultset('Comments')->find($event_data->{id});
    return unless $comment;

    # just send the hash already used for JSON representation
    my $hash = $comment->hash;
    # also include job_id/group_id
    $hash->{job_id}   = $comment->job_id;
    $hash->{group_id} = $comment->group_id;

    log_event($event, $hash);
}

1;
