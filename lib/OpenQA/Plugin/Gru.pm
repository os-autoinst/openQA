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
package OpenQA::Plugin::Gru;

use strict;
use warnings;
use JSON;

use DBIx::Class::Timestamps qw/now/;

use base 'Mojolicious::Plugin';

sub new {
    my $class = shift;
    my $self = $class->SUPER::new(@_);
    $self->{tasks} = {};
    my $app = shift;
    $self->{app} = $app;
    $self->{schema} = $app->db if $app;
    return $self;
}

sub register {

    my ($self, $app, $config) = @_;

    push @{$app->commands->namespaces}, 'OpenQA::Plugin::Gru::Command';

    my $gru = OpenQA::Plugin::Gru->new($app);
    $app->helper(gru => sub {$gru});
}

sub add_task {
    ($_[0]->{tasks}->{$_[1]} = $_[2]) and return $_[0];
}

sub schema {
    my ($self) = @_;
    $self->{schema} ||= OpenQA::Schema::connect_db();
}

sub enqueue {
    my ($self, $task) = (shift, shift);
    my $args    = shift // [];
    my $options = shift // {};

    $self->schema->resultset('GruTasks')->create(
        {
            taskname => $task,
            args => $args,
            priority => $options->{priority} // 0,
            run_at => $options->{run_at} // now()
        }
    );
}

package OpenQA::Plugin::Gru::Command::gru;
use Mojo::Base 'Mojolicious::Command';

has usage       => "usage: $0 gru\n";
has description => 'Run a gru to process jobs';

sub cmd_list {
    my ($self) = @_;

    my $tasks = $self->app->schema->resultset('GruTasks');
    while (my $task = $tasks->next) {
        use Data::Dumper;
        print $task->taskname . " " . Dumper($task->args) . "\n";
    }
}

sub run_first {
    my ($self) = @_;

    my $dtf = $self->app->schema->storage->datetime_parser;
    my $where = { run_at => { '<=',$dtf->format_datetime(DBIx::Class::Timestamps::now()) } };
    my $first = $self->app->schema->resultset('GruTasks')->search($where,{ order_by => qw/id/ })->first;

    if ($first) {
        $self->app->log->debug(sprintf("Running Gru task %d(%s)", $first->id, $first->taskname));
        my $subref = $self->app->gru->{tasks}->{$first->taskname};
        if ($subref) {
            eval { &$subref($self->app, $first->args) };
            if ($@) {
                print $@ . "\n";
                return;
            }
            $first->delete;
            return 1;
        }
    }
}

sub cmd_run {
    my $self = shift;
    my $opt = $_[0] || '';
    while (1) {
        if (!$self->run_first) {
            if ($opt eq '-o') {
                return;
            }
            sleep(5);
        }
    }
}

sub run {
    # only fetch first 2 args
    my $self = shift;
    my $cmd = shift;
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
