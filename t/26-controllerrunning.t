#!/usr/bin/env perl
# Copyright (C) 2017-2020 SUSE LLC
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

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib";
use DateTime;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '6';
use OpenQA::WebAPI::Controller::Running;
use OpenQA::Jobs::Constants;
use Mojolicious;
use Mojo::File 'path';
use Mojo::IOLoop;

my $log_messages = '';

subtest streamtext => sub {
    my $buffer = '';
    my $id     = Mojo::IOLoop->server(
        (address => '127.0.0.1') => sub {
            my ($loop, $stream) = @_;
            $buffer .= 'accepted';
            $stream->on(
                read => sub {
                    my ($stream, $chunk) = @_;
                    $buffer .= $chunk;
                });
        });
    my $port   = Mojo::IOLoop->acceptor($id)->port;
    my $delay  = Mojo::IOLoop->delay;
    my $end    = $delay->begin;
    my $handle = undef;
    Mojo::IOLoop->client(
        {port => $port} => sub {
            my ($loop, $err, $stream) = @_;
            $handle = $stream->steal_handle;
            $end->();
        });
    $delay->wait;

    my $stream = Mojo::IOLoop::Stream->new($handle);
    $id = Mojo::IOLoop->stream($stream);
    my $log        = Mojo::Log->new;
    my $contapp    = Mojolicious->new(log => $log);
    my $controller = OpenQA::WebAPI::Controller::Running->new(app => $contapp);
    my $faketx     = Mojo::Transaction::Fake->new(fakestream => $id);
    $log->unsubscribe('message');
    $log->on(message => sub { my ($log, $level, @lines) = @_; $log_messages .= join "\n", @lines, '' });
    $controller->tx($faketx);
    $controller->stash("job", Job->new);

    my @fake_data = ("Foo bar\n", "Foo baz\n", "bar\n");
    my $t_file    = path($controller->stash("job")->worker->{WORKER_TMPDIR})->child("test.txt");

    # Fill our fake data to stream
    $t_file->spurt(@fake_data);
    $controller->streamtext("test.txt");

    ok !!Mojo::IOLoop->stream($id), 'stream exists';
    like $controller->tx->res->content->{body_buffer}, qr/data: \["Foo bar\\n"\]/, 'body buffer contains "Foo bar"';
    like $controller->tx->res->content->{body_buffer}, qr/data: \["Foo baz\\n"\]/, 'body buffer contains "Foo baz"';
    like $controller->tx->res->content->{body_buffer}, qr/data: \["bar\\n"\]/,     'body buffer contains "bar"';

    my $fake_data = "A\n" x (12 * 1024);
    $t_file->spurt($fake_data);
    $controller->streamtext("test.txt");

    my $size = -s $t_file;
    ok $size > (10 * 1024), "test file size is greater than 10 * 1024";
    like $controller->tx->res->content->{body_buffer}, qr/data: \["A\\n"\]/, 'body buffer contains "A"';
} or diag explain $log_messages;

subtest init => sub {
    use Mojo::Util 'monkey_patch';

    my $app = Mojolicious->new();
    $app->attr("schema", sub { FakeSchema->new() });
    my $not_found;
    my $render_specific_not_found;
    my $render;
    monkey_patch 'OpenQA::WebAPI::Controller::Running', not_found => sub { $not_found = 1 };
    monkey_patch 'OpenQA::WebAPI::Controller::Running',
      render_specific_not_found => sub { $render_specific_not_found = 1 };
    monkey_patch 'OpenQA::WebAPI::Controller::Running', reply  => sub { shift };
    monkey_patch 'OpenQA::WebAPI::Controller::Running', render => sub { shift; $render = [@_] };

    my $c = OpenQA::WebAPI::Controller::Running->new(app => $app);
    $c->param(testid => 'foobar');

    # No job could be found
    my $ret = $c->init();
    is $ret,       0,     'Init returns 0';
    is $not_found, 1,     'Init returns 0 - no defined job';
    is $render,    undef, 'Init returns - not rendering job state';

    # Init should return 1 now
    monkey_patch 'FakeSchema::Find', find => sub { Job->new };
    $ret = $c->init();
    is $ret, 1, 'Init returns 1';
    my $job = $c->stash('job');
    isa_ok($job, 'Job', 'Init correctly stashes the fake Job');

    # Job can be found, but with no worker
    monkey_patch 'Job', worker => sub { undef };
    # status route
    $render_specific_not_found = $render = 0;
    $ret                       = $c->init('status');
    is $ret,                       0, 'init returns 0';
    is $render_specific_not_found, 0, 'no 404 despite no worker';
    is_deeply $render,             [json => {state => RUNNING, result => NONE}], 'job state rendered without worker'
      or diag explain $render;
    # other routes
    $render_specific_not_found = $render = 0;
    $ret                       = $c->init();
    is $ret,                       0, 'init returns 0';
    is $render_specific_not_found, 1, 'specific 404 error rendered';
    is $render,                    0, 'not rendering job state' or diag explain $render;
};

subtest edit => sub {
    use Mojo::Util 'monkey_patch';

    my $app = Mojolicious->new();
    $app->attr("schema", sub { FakeSchema->new() });
    my $not_found;
    my $render_specific_not_found;
    my $found;
    monkey_patch 'OpenQA::WebAPI::Controller::Running', init      => sub { 1 };
    monkey_patch 'FakeSchema::Find',                    find      => sub { undef };
    monkey_patch 'OpenQA::WebAPI::Controller::Running', not_found => sub { $not_found = 1 };
    monkey_patch 'OpenQA::WebAPI::Controller::Running',
      render_specific_not_found => sub { $render_specific_not_found = 1 };
    monkey_patch 'OpenQA::WebAPI::Controller::Running', reply => sub { shift };

    # No results
    my $c = OpenQA::WebAPI::Controller::Running->new(app => $app);
    $c->param('testid', "foobar");
    $c->stash("job", Job->new);
    $c->edit();
    is $render_specific_not_found, 1, "No results";

    # Check if we can get the fake results
    my $details_count;
    monkey_patch 'FakeSchema::Find',                    find        => sub { Job->new };
    monkey_patch 'OpenQA::WebAPI::Controller::Running', redirect_to => sub { $found = 1; $details_count = $_[5]; };
    $c = OpenQA::WebAPI::Controller::Running->new(app => $app);
    $c->param('testid', "foobar");
    $c->stash("job", Job->new);
    $c->edit();
    is $found,         1, "Redirecting to results";
    is $details_count, 3, "Fake results are correct";
};

done_testing;

package Job;
sub new {
    my ($class) = @_;
    my $self = bless({}, $class);
    $self->{worker} = Worker->new;
    return $self;
}

sub worker  { shift->{worker} }
sub state   { OpenQA::Jobs::Constants::RUNNING }
sub result  { OpenQA::Jobs::Constants::NONE }
sub modules { FakeSchema::Find->new }
sub results { {details => [qw(foo bar baz)]} }
sub name    { "foobar" }

package Worker;
use Mojo::File 'tempdir';
sub new {
    my ($class) = @_;
    my $self = bless({}, $class);
    $self->{WORKER_TMPDIR} = tempdir;
    return $self;
}

sub get_property { shift->{WORKER_TMPDIR} }

package Mojo::Transaction::Fake;
use Mojo::Base 'Mojo::Transaction';
sub resume     { ++$_[0]{writing} and return $_[0]->emit('resume') }
sub connection { shift->{fakestream} }

package FakeSchema;
sub new {
    my ($class) = @_;
    my $self = bless({}, $class);
    $self->{resultset} = Worker->new;
    return $self;
}

sub resultset { FakeSchema::Find->new }

package FakeSchema::Find;
sub new  { bless({}, shift) }
sub find { undef }
