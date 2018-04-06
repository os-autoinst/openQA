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
use Data::Dumper;
use Scalar::Util ();

use DBIx::Class::Timestamps 'now';
use Mojo::Base 'Mojolicious::Plugin';
use Mojo::Pg;

has [qw(app dsn)];

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);
    #$self->{tasks} = {};
    my $app = shift;
    $self->app($app);
    Scalar::Util::weaken $self->{app};
    #  $self->{schema} = $self->app->db if $self->app;
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

    $self->dsn(
        ref $self->schema->storage->connect_info->[0] eq 'HASH' ?
          $self->schema->dsn
        : $self->schema->storage->connect_info->[0]);
    $app->plugin(Minion => {Pg => Mojo::Pg->new->dsn($self->dsn)});

    $self->register_tasks;

    push @{$app->commands->namespaces}, 'OpenQA::WebAPI::Plugin::Gru::Command';

    my $gru = OpenQA::WebAPI::Plugin::Gru->new($app);
    $app->helper(gru => sub { $gru });
}

sub schema {
    my ($self) = @_;
    $self->{schema} ||= OpenQA::Schema::connect_db();
}

sub enqueue {
    my ($self, $task) = (shift, shift);
    my $args = shift // [];
    my $options = shift // {};

    $args = [$args] if ref $args eq 'HASH';

    my $delay = $options->{run_at} && $options->{run_at} > now() ? $options->{run_at} - now() : 0;

    $self->app->minion->enqueue($task => $args => {priority => $options->{priority} // 0, delay => $delay});
}

package OpenQA::WebAPI::Plugin::Gru::Command::gru;
use Mojo::Base 'Mojolicious::Command';
#use Minion;
use Mojo::Pg;
use Data::Dumper;
#use OpenQA::WebAPI::Plugin::Gru;

has usage       => "usage: $0 gru [-o]\n";
has description => 'Run a gru to process jobs - give -o to exit _o_nce everything is done';

sub cmd_list {
    my ($self) = @_;
    my $tasks = $self->app->minion->backend->list_jobs();
    foreach my $j (@{$tasks->{jobs}}) {
        print $j->{task} . " " . Dumper($j->{args}) . " result: " . $j->{result} . "\n";
    }
}

sub cmd_run {
    my $self = shift;
    my $opt = $_[0] || '';

    my $worker = $self->app->minion->repair->worker->register;

    if ($opt eq '-o') {
        while (my $job = $worker->register->dequeue(0)) { $job->finish unless defined(my $err = $job->_run) }
        return $worker->unregister;
    }

    while (1) {
        next unless my $job = $worker->register->dequeue(5);
        $job->finish unless defined(my $err = $job->_run);
        sleep 2;
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
