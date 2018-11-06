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

use strict;
use warnings;
use Cpanel::JSON::XS;
use Minion;
use Scalar::Util ();

use DBIx::Class::Timestamps 'now';
use Mojo::Base 'Mojolicious::Plugin';
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

    push @{$app->commands->namespaces}, 'OpenQA::WebAPI::Plugin::Gru::Command';

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
    my $args = shift // [];
    my $options = shift // {};
    my $jobs = shift // [];
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

    return wantarray ? ($minion_id, $gru_id) : $minion_id;
}

# enqueues the limit_assets task with the default parameters
sub enqueue_limit_assets {
    my ($self) = @_;
    return $self->enqueue(limit_assets => [] => {priority => 10, ttl => 172800, limit => 1});
}

package OpenQA::WebAPI::Plugin::Gru::Command::gru;
use Mojo::Base 'Mojolicious::Command';
use Mojo::Pg;
use Minion::Command::minion::job;
use OpenQA::Utils 'log_error';

has usage       => "usage: $0 gru [-o]\n";
has description => 'Run a gru to process jobs - give -o to exit _o_nce everything is done';
has job         => sub { Minion::Command::minion::job->new(app => shift->app) };

sub delete_gru {
    my ($self, $id) = @_;
    my $gru = $self->app->db->resultset('GruTasks')->find($id);
    $gru->delete() if $gru;
}

sub fail_gru {
    my ($self, $id, $reason) = @_;
    my $gru = $self->app->db->resultset('GruTasks')->find($id);
    $gru->fail($reason) if $gru;
}

sub cmd_list { shift->job->run(@_) }

sub execute_job {
    my ($self, $job) = @_;

    my $ttl       = $job->info->{notes}{ttl};
    my $elapsed   = time - $job->info->{created};
    my $ttl_error = 'TTL Expired';

    return
      exists $job->info->{notes}{gru_id} ?
      $job->fail({error => $ttl_error}) && $self->fail_gru($job->info->{notes}{gru_id} => $ttl_error)
      : $job->fail({error => $ttl_error})
      if (defined $ttl && $elapsed > $ttl);

    my $buffer;
    my $err;
    {
        open my $handle, '>', \$buffer;
        local *STDERR = $handle;
        local *STDOUT = $handle;
        $err = $job->execute;
    };

    if (defined $err) {
        log_error("Gru command issue: $err");
        $self->fail_gru($job->info->{notes}{gru_id} => $err)
          if $job->fail({(output => $buffer) x !!(defined $buffer), error => $err})
          && exists $job->info->{notes}{gru_id};
    }
    else {
        $job->finish(defined $buffer ? $buffer : 'Job successfully executed');
        $self->delete_gru($job->info->{notes}{gru_id}) if exists $job->info->{notes}{gru_id};
    }

}

sub cmd_run {
    my $self = shift;
    my $opt = $_[0] || '';

    my $worker = $self->app->minion->repair->worker->register;

    if ($opt eq '-o') {
        while (my $job = $worker->register->dequeue(0)) {
            $self->execute_job($job);
        }
        return $worker->unregister;
    }

    while (1) {
        next unless my $job = $worker->register->dequeue(5);
        $self->execute_job($job);
        sleep 5;
    }
    $worker->unregister;
}

sub run {
    # only fetch first 2 args
    my $self = shift;
    my $cmd  = shift;

    if (!$cmd) {
        print "gru: [list|run]\n";
        return;
    }
    if ($cmd eq 'list') {
        $self->cmd_list(@_);
        return;
    }
    if ($cmd eq 'run') {
        $self->cmd_run(@_);
        return;
    }
}

1;
