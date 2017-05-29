#!/usr/bin/env perl -w
# Copyright (C) 2017 SUSE LLC
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

BEGIN {
    unshift @INC, 'lib';
}

use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/lib";
use DateTime;
use Test::More;
use Test::Warnings;
use OpenQA::WebAPI::Controller::Running;
use Mojolicious;

subtest streamtext => sub {
    use Mojo::File qw(tempdir path);
    use Mojo::IOLoop;
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
    my $controller = OpenQA::WebAPI::Controller::Running->new(app => Mojolicious->new);
    $controller->tx(Mojo::Transaction::Fake->new(fakestream => $id));
    $controller->stash("job", Job->new);

    my @fake_data = ("Foo bar\n", "Foo baz\n", "bar\n");
    my $t_file = path($controller->stash("job")->worker->{WORKER_TMPDIR})->child("test.txt");

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
};

subtest init => sub {
    use Mojo::Util 'monkey_patch';

    my $app = Mojolicious->new();
    $app->attr("schema", sub { FakeSchema->new() });
    my $not_found;
    my $render;
    monkey_patch 'OpenQA::WebAPI::Controller::Running', not_found => sub { $not_found = 1 };
    monkey_patch 'OpenQA::WebAPI::Controller::Running', reply     => sub { shift };
    monkey_patch 'OpenQA::WebAPI::Controller::Running', render    => sub { $render    = 1 };

    my $c = OpenQA::WebAPI::Controller::Running->new(app => $app);
    $c->param('testid', "foobar");

    # No job could be found
    my $ret = $c->init();
    is $ret,       0,     "Init returns 0";
    is $not_found, 1,     "Init returns 0 - no defined job";
    is $render,    undef, "Init returns - not rendering job state";

    # Init should return 1 now
    monkey_patch 'FakeSchema::Find', find => sub { Job->new };
    $ret = $c->init();
    is $ret, 1, "Init returns 1";
    my $job = $c->stash("job");
    isa_ok($job, "Job", "Init correctly stashes the fake Job");

    # Job can be found, but with no worker
    monkey_patch 'Job', worker => sub { undef };
    $ret = $c->init();
    is $ret,    0, "Init returns 0";
    is $render, 1, "Init returns 0 - no defined worker";
};

subtest edit => sub {
    use Mojo::Util 'monkey_patch';

    my $app = Mojolicious->new();
    $app->attr("schema", sub { FakeSchema->new() });
    my $not_found;
    my $found;
    monkey_patch 'OpenQA::WebAPI::Controller::Running', init      => sub { 1 };
    monkey_patch 'FakeSchema::Find',                    find      => sub { undef };
    monkey_patch 'OpenQA::WebAPI::Controller::Running', not_found => sub { $not_found = 1 };
    monkey_patch 'OpenQA::WebAPI::Controller::Running', reply     => sub { shift };

    # No results
    my $c = OpenQA::WebAPI::Controller::Running->new(app => $app);
    $c->param('testid', "foobar");
    $c->stash("job", Job->new);
    $c->edit();
    is $not_found, 1, "No results";

    # Check if we can get the fake results
    my $details_count;
    monkey_patch 'FakeSchema::Find', find => sub { Job->new };
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
sub state   { 1 }
sub modules { FakeSchema::Find->new }
sub details { [qw(foo bar baz)] }
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
sub resume { ++$_[0]{writing} and return $_[0]->emit('resume') }
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
sub new { bless({}, shift) }
sub find { undef }
