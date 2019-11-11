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

use constant DEFAULT_MINION_WORKERS => 5;

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

    $self->plugin('OpenQA::CacheService::Plugin::Helpers');

    my $r = $self->routes;
    $r->get('/' => sub { shift->redirect_to('/minion') });
    $r->get('/info')->to('API#info');
    $r->get('/status/<id:num>')->to('API#status');
    $r->post('/enqueue')->to('API#enqueue');
    $r->any('/*whatever' => {whatever => ''})->to(status => 404, text => 'Not found');
}

sub setup_workers {
    return @_ unless grep { $_ eq 'worker' } @_;
    my @args = @_;

    my $global_settings = OpenQA::Worker::Settings->new->global_settings;
    my $cache_workers
      = exists $global_settings->{CACHEWORKERS} ? $global_settings->{CACHEWORKERS} : DEFAULT_MINION_WORKERS;
    push @args, '-j', $cache_workers;

    return @args;
}

sub run {
    my @args = setup_workers(@_);

    my $app = __PACKAGE__->new;
    $app->log->short(1);
    $ENV{MOJO_INACTIVITY_TIMEOUT} //= 300;
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
    OpenQA::CacheService::run(qw(daemon));

    # Start one or more Minions
    OpenQA::CacheService::run(qw(minion worker))

=head1 DESCRIPTION

OpenQA::CacheService is the OpenQA Cache Service, which is meant to be run
standalone.

=head1 GET ROUTES

OpenQA::CacheService is a L<Mojolicious::Lite> application, and it is exposing the following GET routes.

=head2 /minion

Redirects to the L<Mojolicious::Plugin::Minion::Admin> Dashboard.

=head2 /info

Returns Minon statistics, see L<https://metacpan.org/pod/Minion#stats>.

=head2 /status/<id>

Retrieve current job status in JSON format.

=head1 POST ROUTES

OpenQA::CacheService is exposing the following POST routes.

=head2 /enqueue

Enqueue the task. It acceps a POST JSON payload of the form:

      {task => 'cache_assets', args => [qw(42 test hdd open.qa)], lock => 'some lock'}

=cut
