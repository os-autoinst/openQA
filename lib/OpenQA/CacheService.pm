# Copyright (C) 2018-2019 SUSE LLC
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

package OpenQA::CacheService;
use Mojo::Base 'Mojolicious';

use OpenQA::Worker::Settings;
use OpenQA::CacheService::Model::Cache
  qw(STATUS_PROCESSED STATUS_ENQUEUED STATUS_DOWNLOADING STATUS_IGNORE STATUS_ERROR);
use Mojo::Collection;
use Mojo::Util 'md5_sum';

use constant DEFAULT_MINION_WORKERS => 5;

BEGIN { srand(time) }

my $_token;

sub _gen_session_token { $_token = md5_sum($$ . time . rand) }

my $enqueued = Mojo::Collection->new;

sub startup {
    my $self = shift;

    $self->hook(
        before_server_start => sub {
            my ($server, $app) = @_;
            $server->silent(1) if $app->mode eq 'test';
            _gen_session_token();
            $enqueued = Mojo::Collection->new;
        });

    $self->plugin(Minion => {SQLite => 'sqlite:' . OpenQA::CacheService::Model::Cache->from_worker->db_file});
    $self->plugin('Minion::Admin');
    $self->plugin('OpenQA::CacheService::Task::Asset');
    $self->plugin('OpenQA::CacheService::Task::Sync');

    my $r = $self->routes;

    $r->get('/session_token' => sub { shift->render(json => {session_token => SESSION_TOKEN()}) });

    $r->get('/info' => sub { $_[0]->render(json => shift->minion->stats) });

    $r->post(
        '/status' => sub {
            my $c         = shift;
            my $data      = $c->req->json;
            my $lock_name = $data->{lock};
            return $c->render(json => {error => 'No lock specified.'}, status => 400) unless $lock_name;

            my $lock = _gen_guard_name($lock_name);
            my %res
              = (status =>
                  ($c->app->_active($lock) ? STATUS_DOWNLOADING : enqueued($lock) ? STATUS_IGNORE : STATUS_PROCESSED));

            if ($data->{id}) {
                my $job = $c->minion->job($data->{id});
                return $c->render(json => {error => 'Specified job ID is invalid.'}, status => 404) unless $job;

                my $job_info = $job->info;
                return $c->render(json => {error => 'Job info not available.'}, status => 404) unless $job_info;
                $res{result} = $job_info->{result};
                $res{output} = $job_info->{notes}->{output};
            }

            $c->render(json => \%res);
        });

    $r->post(
        '/execute_task' => sub {
            my $c    = shift;
            my $data = $c->req->json;
            my $task = $data->{task};
            my $args = $data->{args};

            return $c->render(json => {status => STATUS_ERROR, error => 'No Task defined'})
              unless defined $task;
            return $c->render(json => {status => STATUS_ERROR, error => 'No Arguments defined'})
              unless defined $args;

            my $lock = _gen_guard_name($data->{lock} ? $data->{lock} : @$args);
            $c->app->log->debug("Requested [$task] Args: @{$args} Lock: $lock");

            return $c->render(json => {status => STATUS_DOWNLOADING()}) if $c->app->_active($lock);
            return $c->render(json => {status => STATUS_IGNORE()})      if enqueued($lock);

            enqueue($lock);
            my $id = $c->minion->enqueue($task => $args);

            $c->render(json => {status => STATUS_ENQUEUED, id => $id});
        });

    $r->get('/' => sub { shift->redirect_to('/minion') });

    $r->post(
        '/dequeue' => sub {
            my $c    = shift;
            my $data = $c->req->json;
            dequeue(_gen_guard_name($data->{lock}));
            $c->render(json => {status => STATUS_PROCESSED});
        });
}

sub SESSION_TOKEN { $_token }

sub _gen_guard_name { join('.', SESSION_TOKEN, pop) }

sub _exists { !!(defined $_[0] && exists $_[0]->{total} && $_[0]->{total} > 0) }

sub _active { !shift->minion->lock(shift, 0) }

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

    my @args            = @_;
    my $global_settings = OpenQA::Worker::Settings->new->global_settings;
    my $cache_workers
      = exists $global_settings->{CACHEWORKERS} ? $global_settings->{CACHEWORKERS} : DEFAULT_MINION_WORKERS;
    push(@args, '-j', $cache_workers);
    return @args;
}

sub run {
    my @args = _setup_workers(@_);

    my $app = __PACKAGE__->new;
    $app->log->short(1);
    local $ENV{MOJO_INACTIVITY_TIMEOUT} //= 300;
    $app->log->debug("Starting cache service: $0 @args");

    return $app->start(@args);
}

1;

=encoding utf-8

=head1 NAME

OpenQA::CacheService - OpenQA Cache Service

=head1 SYNOPSIS

    use OpenQA::CacheService;

    # Start the daemon
    OpenQA::CacheService->run(qw(daemon));

    # Start one or more Minions with:
    OpenQA::CacheService->run(qw(minion worker))

=head1 DESCRIPTION

OpenQA::CacheService is the OpenQA Cache Service, which is meant to be run
standalone.

=head1 GET ROUTES

OpenQA::CacheService is a L<Mojolicious::Lite> application, and it is exposing the following GET routes.

=head2 /minion

Redirects to the L<Mojolicious::Plugin::Minion::Admin> Dashboard.

=head2 /info

Returns Minon statistics, see L<https://metacpan.org/pod/Minion#stats>.

=head2 /session_token

Returns the current session token.

=head1 POST ROUTES

OpenQA::CacheService is exposing the following POST routes.

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
