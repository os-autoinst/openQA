# Copyright (C) 2018 SUSE LLC
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

package OpenQA::Worker::Cache::Service;

use Mojolicious::Lite;
use OpenQA::Worker::Cache::Task::Asset;
use Mojolicious::Plugin::Minion;
use OpenQA::Worker::Cache qw(STATUS_PROCESSED STATUS_ENQUEUED STATUS_DOWNLOADING STATUS_IGNORE STATUS_ERROR);
use Mojo::Collection;
use Mojolicious::Plugin::Minion::Admin;
use Mojo::Util 'md5_sum';

use constant DEFAULT_MINION_WORKERS => 5;

BEGIN { srand(time) }

my $_token;

sub _gen_session_token { $_token = md5_sum($$ . time . rand) }

my $enqueued = Mojo::Collection->new;
app->hook(
    before_server_start => sub {
        my ($server, $app) = @_;
        $server->silent(1) if $app->mode eq 'test';
        _gen_session_token();
        $enqueued = Mojo::Collection->new;
    });

plugin Minion => {SQLite => 'sqlite:' . OpenQA::Worker::Cache->from_worker->db_file};
plugin 'Minion::Admin';
plugin 'OpenQA::Worker::Cache::Task::Asset';
plugin 'OpenQA::Worker::Cache::Task::Sync';

sub SESSION_TOKEN { $_token }

sub _gen_guard_name { join('.', SESSION_TOKEN, pop) }

sub _exists { !!(defined $_[0] && exists $_[0]->{total} && $_[0]->{total} > 0) }

sub active { !app->minion->lock(shift, 0) }

sub enqueued {
    my $lock = shift;
    !!($enqueued->grep(sub { $_ eq $lock })->size == 1);
}

sub dequeue {
    my $lock = shift;
    $enqueued = $enqueued->grep(sub { $_ ne $lock });
}

sub enqueue {
    push @$enqueued, shift;
}

sub _setup_workers {
    return @_ unless grep { /worker/i } @_;

    require OpenQA::Worker::Common;
    my @args = @_;
    my ($worker_settings, undef) = OpenQA::Worker::Common::read_worker_config(undef, undef);
    my $cache_workers
      = exists $worker_settings->{CACHEWORKERS} ? $worker_settings->{CACHEWORKERS} : DEFAULT_MINION_WORKERS;
    push(@args, '-j', $cache_workers);
    return @args;
}

sub run {
    my $self = shift;
    app->log->short(1);
    require OpenQA::Utils;
    OpenQA::Utils::set_listen_address(7844);
    $ENV{MOJO_INACTIVITY_TIMEOUT} //= 300;
    my @args = _setup_workers(@_);
    app->log->debug("Starting cache service: $0 @args");
    app->start(@args);
}

get '/session_token' => sub { shift->render(json => {session_token => SESSION_TOKEN()}) };

get '/info' => sub { $_[0]->render(json => shift->minion->stats) };

post '/status' => sub {
    my $c         = shift;
    my $data      = $c->req->json;
    my $lock_name = $data->{lock};
    return $c->render(json => {error => 'No lock specified.'}, status => 400) unless $lock_name;

    my $lock = _gen_guard_name($lock_name);
    my %res  = (status => (active($lock) ? STATUS_DOWNLOADING : enqueued($lock) ? STATUS_IGNORE : STATUS_PROCESSED));

    if ($data->{id}) {
        my $job = app->minion->job($data->{id});
        return $c->render(json => {error => 'Specified job ID is invalid.'}, status => 404) unless $job;

        my $job_info = $job->info;
        return $c->render(json => {error => 'Job info not available.'}, status => 404) unless $job_info;
        $res{result} = $job_info->{result};
        $res{output} = $job_info->{notes}->{output};
    }

    $c->render(json => \%res);
};

post '/execute_task' => sub {
    my $c    = shift;
    my $data = $c->req->json;
    my $task = $data->{task};
    my $args = $data->{args};

    return $c->render(json => {status => STATUS_ERROR, error => 'No Task defined'})
      unless defined $task;
    return $c->render(json => {status => STATUS_ERROR, error => 'No Arguments defined'})
      unless defined $args;

    my $lock = _gen_guard_name($data->{lock} ? $data->{lock} : @$args);
    app->log->debug("Requested [$task] Args: @{$args} Lock: $lock");

    return $c->render(json => {status => STATUS_DOWNLOADING()}) if active($lock);
    return $c->render(json => {status => STATUS_IGNORE()})      if enqueued($lock);

    enqueue($lock);
    my $id = $c->minion->enqueue($task => $args);

    $c->render(json => {status => STATUS_ENQUEUED, id => $id});
};

get '/' => sub { shift->redirect_to('/minion') };

post '/dequeue' => sub {
    my $c    = shift;
    my $data = $c->req->json;
    dequeue(_gen_guard_name($data->{lock}));
    $c->render(json => {status => STATUS_PROCESSED});
};

app->minion->reset;

=encoding utf-8

=head1 NAME

OpenQA::Worker::Cache::Service - OpenQA Cache Service

=head1 SYNOPSIS

    use OpenQA::Worker::Cache::Service;

    # Start the daemon
    OpenQA::Worker::Cache::Service->run(qw(daemon));

    # Start one or more Minions with:
    OpenQA::Worker::Cache::Service->run(qw(minion worker))

=head1 DESCRIPTION

OpenQA::Worker::Cache::Service is the OpenQA Cache Service, which is meant to be run
standalone.

=head1 GET ROUTES

OpenQA::Worker::Cache::Service is a L<Mojolicious::Lite> application, and it is exposing the following GET routes.

=head2 /minion

Redirects to the L<Mojolicious::Plugin::Minion::Admin> Dashboard.

=head2 /info

Returns Minon statistics, see L<https://metacpan.org/pod/Minion#stats>.

=head2 /session_token

Returns the current session token.

=head1 POST ROUTES

OpenQA::Worker::Cache::Service is exposing the following POST routes.

=head2 /execute_task

Enqueue the task. It acceps a POST JSON payload of the form:

      { task => 'cache_assets', args => [qw(42 test hdd open.qa)] }

=head2 /status

Retrieve download asset status. It acceps a POST JSON payload of the form:

      { asset=> 'default.qcow2' }

=head2 /dequeue

Dequeues a job from the queue of jobs which are still inactive. It acceps a POST JSON payload of the form:

      { asset=> 'default.qcow2' }

=cut

1;
