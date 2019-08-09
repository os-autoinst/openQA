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
use OpenQA::Schema;
use OpenQA::Utils;
use Mojo::Pg;
use Mojo::Promise;

has app => undef, weak => 1;
has 'dsn';

sub new {
    my ($class, $app) = @_;
    my $self = $class->SUPER::new;
    return $self->app($app);
}

sub register_tasks {
    my $self = shift;

    my $app = $self->app;
    $app->plugin($_)
      for (
        qw(OpenQA::Task::AuditEvents::Limit),
        qw(OpenQA::Task::Asset::Download OpenQA::Task::Asset::Limit),
        qw(OpenQA::Task::Needle::Scan OpenQA::Task::Needle::Save OpenQA::Task::Needle::Delete),
        qw(OpenQA::Task::Job::Limit),
        qw(OpenQA::Task::Iso::Schedule),
        qw(OpenQA::Task::Screenshot::Scan),
      );
}

sub register {
    my ($self, $app, $config) = @_;

    $self->app($app) unless $self->app;
    my $schema = $app->schema;

    my $conn = Mojo::Pg->new;
    if (ref $schema->storage->connect_info->[0] eq 'HASH') {
        $self->dsn($schema->dsn);
        $conn->username($schema->storage->connect_info->[0]->{user});
        $conn->password($schema->storage->connect_info->[0]->{password});
    }
    else {
        $self->dsn($schema->storage->connect_info->[0]);
    }
    $conn->dsn($self->dsn());

    # set the search path in accordance with the test setup done in OpenQA::Test::Database
    if (my $search_path = $schema->search_path_for_tests) {
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
    my $self = shift;
    return !!$self->app->minion->backend->list_workers(0, 1)->{total};
}

sub enqueue {
    my ($self, $task, $args, $options, $jobs) = (shift, shift, shift // [], shift // {}, shift // []);

    my $ttl   = $options->{ttl}   ? $options->{ttl}   : undef;
    my $limit = $options->{limit} ? $options->{limit} : undef;
    my $notes = $options->{notes} ? $options->{notes} : undef;
    return undef if defined $limit && $self->count_jobs($task, ['inactive']) >= $limit;

    $args = [$args] if ref $args eq 'HASH';

    my $delay = $options->{run_at} && $options->{run_at} > now() ? $options->{run_at} - now() : 0;

    my $schema = OpenQA::Schema->singleton;
    my $gru    = $schema->resultset('GruTasks')->create(
        {
            taskname => $task,
            priority => $options->{priority} // 0,
            args     => $args,
            run_at   => $options->{run_at} // now(),
            jobs     => $jobs,
        });
    my $gru_id    = $gru->id;
    my @ttl       = defined $ttl ? (ttl => $ttl) : ();
    my @notes     = defined $notes ? (%$notes) : ();
    my $minion_id = $self->app->minion->enqueue(
        $task => $args => {
            priority => $options->{priority} // 0,
            delay    => $delay,
            notes    => {gru_id => $gru_id, @ttl, @notes}});

    return {minion_id => $minion_id, gru_id => $gru_id};
}

# enqueues the limit_assets task with the default parameters
sub enqueue_limit_assets {
    my $self = shift;
    return $self->enqueue(limit_assets => [] => {priority => 10, ttl => 172800, limit => 1});
}

sub enqueue_download_jobs {
    my ($self, $downloads, $job_ids) = @_;
    return unless (%$downloads and @$job_ids);
    # array of hashrefs job_id => id; this is what create needs
    # to create entries in a related table (gru_dependencies)
    my @jobsarray = map +{job_id => $_}, @$job_ids;
    for my $url (keys %$downloads) {
        my ($path, $do_extract) = @{$downloads->{$url}};
        $self->enqueue(download_asset => [$url, $path, $do_extract] => {priority => 20} => \@jobsarray);
    }
}

sub enqueue_and_keep_track {
    my ($self, %args) = @_;

    my $task_name        = $args{task_name};
    my $task_description = $args{task_description};
    my $task_args        = $args{task_args};
    my $task_options     = $args{task_options};

    # set default gru task options
    $task_options = {
        priority => 10,
        ttl      => 60,
    } unless ($task_options);

    # check whether Minion worker are available to get a nice error message instead of an inactive job
    if (!$self->has_workers) {
        return Mojo::Promise->reject(
            {error => 'No Minion worker available. The <code>openqa-gru</code> service is likely not running.'});
    }

    # enqueue Minion job
    my $ids = $self->enqueue($task_name => $task_args, $task_options);
    my $minion_id;
    if (ref $ids eq 'HASH') {
        $minion_id = $ids->{minion_id};
    }

    # keep track of the Minion job and continue rendering if it has completed
    return $self->app->minion->result_p($minion_id, {interval => 0.5})->then(
        sub {
            my ($info) = @_;

            unless (ref $info) {
                return Mojo::Promise->reject({error => "Minion job for $task_description has been removed."});
            }
            return $info->{result};
        }
    )->catch(
        sub {
            my ($info) = @_;

            # pass result hash with error message (used by save/delete needle tasks)
            my $result = $info->{result};
            if (ref $result eq 'HASH' && $result->{error}) {
                return Mojo::Promise->reject($result, 500);
            }

            # format error message (fallback for general case)
            my $error_message;
            if (ref $result eq '' && $result) {
                $error_message = "Task for $task_description failed: $result";
            }
            else {
                $error_message = "Task for $task_description failed: Checkout Minion dashboard for further details.";
            }
            return Mojo::Promise->reject({error => $error_message, result => $result}, 500);
        });
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
