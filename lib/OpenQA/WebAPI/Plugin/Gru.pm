# Copyright (C) 2015-2019 SUSE LLC
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

# a lot of this is inspired (and even in parts copied) from Minion (Artistic-2.0)
package OpenQA::WebAPI::Plugin::Gru;
use Mojo::Base 'Mojolicious::Plugin';

use Minion;
use DBIx::Class::Timestamps 'now';
use OpenQA::Utils;
use Mojo::Pg;

has app => undef, weak => 1;
has 'dsn';

sub new {
    my $self = shift->SUPER::new;
    return $self->app(shift);
}

sub register_tasks {
    my $self = shift;

    my $app = $self->app;
    $app->plugin($_)
      for (
        qw(OpenQA::Task::Asset::Download OpenQA::Task::Asset::Limit OpenQA::Task::Job::Limit),
        qw(OpenQA::Task::Needle::Scan OpenQA::Task::Needle::Save OpenQA::Task::Screenshot::Scan)
      );
}

sub register {
    my ($self, $app, $config) = @_;

    $self->app($app) unless $self->app;
    $self->{schema} = $self->app->db if $self->app->db;

    my $conn = Mojo::Pg->new;
    if (ref $self->schema->storage->connect_info->[0] eq 'HASH') {
        $self->dsn($self->schema->dsn);
        $conn->username($self->schema->storage->connect_info->[0]->{user});
        $conn->password($self->schema->storage->connect_info->[0]->{password});
    }
    else {
        $self->dsn($self->schema->storage->connect_info->[0]);
    }
    $conn->dsn($self->dsn());

    # set the search path in accordance with the test setup done in OpenQA::Test::Database
    if (my $search_path = $ENV{TEST_PG_SEARCH_PATH}) {
        log_info("setting database search path to $search_path when registering Minion plugin\n");
        $conn->search_path([$search_path]);
    }

    $app->plugin(Minion => {Pg => $conn});

    $self->register_tasks;

    # Enable the Minion Admin interface under /minion
    my $auth = $app->routes->under('/minion')->to('session#ensure_admin');
    $app->plugin('Minion::Admin' => {route => $auth});

    my $gru = OpenQA::WebAPI::Plugin::Gru->new($app);
    $app->helper(gru => sub { $gru });
}

sub schema { shift->{schema} ||= OpenQA::Schema::connect_db() }

# counts the number of jobs for a certain task in the specified states
sub count_jobs {
    my ($self, $task, $states) = @_;
    my $res = $self->app->minion->backend->list_jobs(0, undef, {tasks => [$task], states => $states});
    return ($res && exists $res->{total}) ? $res->{total} : 0;
}

# checks whether at least on job for the specified task is active
sub is_task_active {
    my ($self, $task) = @_;
    return $self->count_jobs($task, ['active']) > 0;
}

# checks if there are worker registered
sub has_workers {
    return !!shift->app->minion->backend->list_workers(0, 1)->{total};
}

sub enqueue {
    my ($self, $task, $args, $options, $jobs) = (shift, shift, shift // [], shift // {}, shift // []);

    my $ttl   = $options->{ttl}   ? $options->{ttl}   : undef;
    my $limit = $options->{limit} ? $options->{limit} : undef;
    return undef if defined $limit && $self->count_jobs($task, ['inactive']) >= $limit;

    $args = [$args] if ref $args eq 'HASH';

    my $delay = $options->{run_at} && $options->{run_at} > now() ? $options->{run_at} - now() : 0;

    my $gru = $self->schema->resultset('GruTasks')->create(
        {
            taskname => $task,
            priority => $options->{priority} // 0,
            args     => $args,
            run_at   => $options->{run_at} // now(),
            jobs     => $jobs,
        });
    my $gru_id    = $gru->id;
    my $minion_id = $self->app->minion->enqueue(
        $task => $args => {
            priority => $options->{priority} // 0,
            delay    => $delay,
            notes    => {gru_id => $gru_id, (ttl => $ttl) x !!(defined $ttl)}});

    return {minion_id => $minion_id, gru_id => $gru_id};
}

# enqueues the limit_assets task with the default parameters
sub enqueue_limit_assets {
    my ($self) = @_;
    return $self->enqueue(limit_assets => [] => {priority => 10, ttl => 172800, limit => 1});
}

1;


=encoding utf8

=head1 NAME

OpenQA::WebAPI::Plugin::Gru - The Gru job queue

=head1 SYNOPSIS

    $app->plugin('OpenQA::WebAPI::Plugin::Gru');

=head1 DESCRIPTION

L<OpenQA::WebAPI::Plugin::Gru> is the WebAPI job queue (and a tiny wrapper
around L<Minion>).

=cut
