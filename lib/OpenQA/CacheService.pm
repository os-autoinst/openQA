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
use OpenQA::CacheService::Model::Cache;
use OpenQA::CacheService::Model::Locks;
use Mojo::Util 'md5_sum';

use constant DEFAULT_MINION_WORKERS => 5;

BEGIN { srand(time) }

has session_token => sub { md5_sum($$ . time . rand) };

sub startup {
    my $self = shift;

    $self->defaults(appname => 'openQA Cache Service');

    $self->hook(
        before_server_start => sub {
            my ($server, $app) = @_;
            $server->silent(1) if $app->mode eq 'test';
        });

    $self->plugin(Minion => {SQLite => 'sqlite:' . OpenQA::CacheService::Model::Cache->from_worker->db_file});
    $self->plugin('Minion::Admin');
    $self->plugin('OpenQA::CacheService::Task::Asset');
    $self->plugin('OpenQA::CacheService::Task::Sync');

    $self->helper(locks => sub { state $locks = OpenQA::CacheService::Model::Locks->new });

    $self->helper(gen_guard_name => sub { join('.', shift->app->session_token, shift) });

    my $r = $self->routes;
    $r->get('/' => sub { shift->redirect_to('/minion') });
    $r->get('/session_token')->to('API#session_token');
    $r->get('/info')->to('API#info');
    $r->post('/status')->to('API#status');
    $r->post('/execute_task')->to('API#execute_task');
    $r->post('/dequeue')->to('API#dequeue');
}

sub _setup_workers {
    return @_ unless grep { /worker/i } @_;
    my @args = @_;

    my $global_settings = OpenQA::Worker::Settings->new->global_settings;
    my $cache_workers
      = exists $global_settings->{CACHEWORKERS} ? $global_settings->{CACHEWORKERS} : DEFAULT_MINION_WORKERS;
    push @args, '-j', $cache_workers;

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
