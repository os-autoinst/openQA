# Copyright (C) 2015 SUSE Linux GmbH
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
use Scalar::Util ();
use DBIx::Class::Timestamps 'now';
use Mojo::Pg;

has [qw(app dsn)];

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);
    my $app   = shift;
    $self->app($app);
    Scalar::Util::weaken $self->{app};
    return $self;
}

sub register_tasks {
    my $self = shift;
    my $app  = $self->app;

    $app->plugin($_)
      for (
        qw(OpenQA::Task::Asset::Download OpenQA::Task::Asset::Limit),
        qw(OpenQA::Task::Job::Limit OpenQA::Task::Job::Modules),
        qw(OpenQA::Task::Needle::Scan),
        qw(OpenQA::Task::Screenshot::Scan)
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
    $app->plugin(Minion => {Pg => $conn});
    $self->register_tasks;

    # Enable the Minion Admin interface under /minion
    my $auth = $app->routes->under('/minion')->to('session#ensure_admin');
    $app->plugin('Minion::Admin' => {route => $auth});

    my $gru = OpenQA::WebAPI::Plugin::Gru->new($app);
    $app->helper(gru => sub { $gru });
}

sub schema {
    my ($self) = @_;
    $self->{schema} ||= OpenQA::Schema::connect_db();
}

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

sub enqueue {
    my ($self, $task) = (shift, shift);
    my $args    = shift // [];
    my $options = shift // {};
    my $jobs    = shift // [];
    my $ttl   = $options->{ttl}   ? $options->{ttl}   : undef;
    my $limit = $options->{limit} ? $options->{limit} : undef;

    return if defined $limit && $self->count_jobs($task, ['inactive']) >= $limit;

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
