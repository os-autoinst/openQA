#!/usr/bin/env perl
# Copyright 2017-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

BEGIN {
    $ENV{OPENQA_IMAGE_STREAMING_INTERVAL} = 0.0;
    $ENV{OPENQA_TEXT_STREAMING_INTERVAL} = 0.0;
}

use Test::Most;
use Mojo::Base -base, -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use DateTime;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '6';
use OpenQA::Shared::Controller::Running;
use OpenQA::Jobs::Constants;
use Test::MockModule;
use Test::Output qw(combined_is combined_like);
use Mojolicious;
use Mojo::File 'path';
use Mojo::IOLoop;
use Mojo::IOLoop::Stream;
use Mojo::Promise;
use Mojo::Util 'monkey_patch';

my $log_messages = '';

my $client_mock = Test::MockModule->new('OpenQA::WebSockets::Client');
my @messages;
my $fake_error;
$client_mock->redefine(
    send_msg => sub ($client, $worker_id, $msg, $job_id, $retry = undef, $cb = undef) {
        push @messages, [$worker_id, $msg, $job_id];
        $cb->(undef, Mojo::Transaction::Fake->new(error => $fake_error)) if $cb;
    });

subtest streaming => sub {
    # mock controller to invoke drain callback and be able to check whether finish is called
    my $c_mock = Test::MockModule->new('OpenQA::Shared::Controller::Running');
    my $c_finished = 0;
    $c_mock->redefine(finish => sub ($self) { $self->tx->finish; $c_finished = 1 });
    $c_mock->redefine(
        write => sub ($self, $data, $drain_cb = undef) {
            $c_mock->original('write')->($self, $data);
            Mojo::IOLoop->next_tick(sub ($loop) { $drain_cb->($self) }) if defined $drain_cb;
        });

    # setup controller
    my $stream = Mojo::IOLoop::Stream->new;
    my $id = Mojo::IOLoop->stream($stream);
    my $log = Mojo::Log->new;
    my $app = Mojolicious->new(log => $log);
    push @{$app->plugins->namespaces}, 'OpenQA::Shared::Plugin';
    $app->plugin('SharedHelpers');

    subtest textfile => sub {
        my $controller = OpenQA::Shared::Controller::Running->new(app => $app);
        my $faketx = Mojo::Transaction::Fake->new(fakestream => $id);
        $log->unsubscribe('message');
        $log->on(message => sub { my ($log, $level, @lines) = @_; $log_messages .= join "\n", @lines, '' });
        $controller->tx($faketx);
        $controller->stash('job', Job->new);

        # setup fake textfile
        my @fake_data = ("Foo bar\n", "Foo baz\n", "bar\n");
        my $tmpdir = path($controller->stash('job')->worker->{WORKER_TMPDIR});
        my $t_file = $tmpdir->child('test.txt');
        $t_file->spew(join '', @fake_data);

        # test text streaming
        $controller->streamtext('test.txt');
        ok !!Mojo::IOLoop->stream($id), 'stream exists';
        like $controller->tx->res->content->{body_buffer}, qr/data: \["Foo bar\\n"\]/, 'body buffer contains "Foo bar"';
        like $controller->tx->res->content->{body_buffer}, qr/data: \["Foo baz\\n"\]/, 'body buffer contains "Foo baz"';
        like $controller->tx->res->content->{body_buffer}, qr/data: \["bar\\n"\]/, 'body buffer contains "bar"';

        my $fake_data = "A\n" x (12 * 1024);
        $t_file->spew($fake_data);
        $controller->streamtext('test.txt');

        my $size = -s $t_file;
        ok $size > (10 * 1024), 'test file size is greater than 10 * 1024';
        like $controller->tx->res->content->{body_buffer}, qr/data: \["A\\n"\]/, 'body buffer contains "A"';
        Mojo::IOLoop->one_tick;
    };

    subtest image => sub {
        $app->attr(schema => sub { FakeSchema->new() });
        my $controller = OpenQA::Shared::Controller::Running->new(app => $app);
        my $faketx = Mojo::Transaction::Fake->new(fakestream => $id);
        $controller->tx($faketx);
        monkey_patch 'FakeSchema::Find', find => sub ($self, @) { $self->{name} eq 'Workers' ? Worker->new : Job->new };
        combined_like { $controller->streaming } qr/Asking the worker 43 to start providing livestream for job 42/,
          'reached code for enabling livestream';
        is $controller->res->code, 200, 'tempdir not found';
        is_deeply \@messages, [[43, 'livelog_start', 42]], 'livelog started' or always_explain \@messages;
        Mojo::IOLoop->one_tick;
        is $controller->res->body, '', 'body still empty as there is no image yet';

        my $tmpdir = path($controller->stash('job')->worker->{WORKER_TMPDIR});
        my $fake_png = $tmpdir->child('01-fake.png');
        my $last_png = $tmpdir->child('last.png');
        $fake_png->spew('not actually a PNG');
        symlink $fake_png->basename, $last_png or die "Unable to symlink: $!";
        combined_is { Mojo::IOLoop->one_tick } '', 'timer/callback does not clutter log (1)';
        is $controller->res->content->{body_buffer}, "data: data:image/png;base64,bm90IGFjdHVhbGx5IGEgUE5H\n\n",
          'base64-encoded fake PNG sent';
        $last_png->remove;
        symlink '02-fake.png', $last_png or die "Unable to symlink: $!";
        ok !$c_finished, 'controller has not been finished yet';
        combined_is { Mojo::IOLoop->one_tick } '', 'timer/callback does not clutter log (2)';
        like $controller->res->content->{body_buffer}, qr/data: Unable to read image: Can't open file.*\n\n/,
          'error sent if PNG does not exist';
        Mojo::IOLoop->one_tick;
        ok $c_finished, 'controller has been finished';
    };

    subtest fake => sub {
        @messages = ();
        $fake_error = {message => 'fake error'};
        my $controller = OpenQA::Shared::Controller::Running->new(app => $app);
        my $faketx = Mojo::Transaction::Fake->new(fakestream => $id);
        $controller->tx($faketx);
        combined_like { $controller->streaming } qr/Unable to ask .* providing livestream .*: fake error/,
          'error sending livestream command is logged';
        like $controller->res->content->{body_buffer}, qr/data: .* fake error/, 'error written as stream data';
    };

    subtest 'no worker' => sub {
        @messages = ();
        my $controller = OpenQA::Shared::Controller::Running->new(app => $app);
        my $faketx = Mojo::Transaction::Fake->new(fakestream => $id);
        $controller->tx($faketx);
        my $orig = \&Job::worker;
        monkey_patch 'Job', worker => sub { undef };
        $controller->streaming;
        is $controller->res->code, 404, 'no worker';
        is_deeply \@messages, [], 'no worker' or always_explain \@messages;
        monkey_patch 'Job', worker => $orig;
    };
} or always_explain $log_messages;

subtest init => sub {
    my $app = Mojolicious->new();
    $app->attr('schema', sub { FakeSchema->new() });
    my $not_found;
    my $render_specific_not_found;
    my $render;
    monkey_patch 'OpenQA::Shared::Controller::Running', not_found => sub { $not_found = 1 };
    monkey_patch 'OpenQA::Shared::Controller::Running',
      render_specific_not_found => sub { $render_specific_not_found = 1 };
    monkey_patch 'OpenQA::Shared::Controller::Running', reply => sub { shift };
    monkey_patch 'OpenQA::Shared::Controller::Running', render => sub { shift; $render = [@_] };

    my $c = OpenQA::Shared::Controller::Running->new(app => $app);
    $c->param(testid => 'foobar');

    # No job could be found
    monkey_patch 'FakeSchema::Find', find => sub { undef };
    my $ret = $c->init();
    is $ret, 0, 'Init returns 0';
    is $not_found, 1, 'Init returns 0 - no defined job';
    is $render, undef, 'Init returns - not rendering job state';

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
    $ret = $c->init('status');
    is $ret, 0, 'init returns 0';
    is $render_specific_not_found, 0, 'no 404 despite no worker';
    is_deeply $render, [json => {state => RUNNING, result => NONE}], 'job state rendered without worker'
      or always_explain $render;
    # other routes
    $render_specific_not_found = $render = 0;
    $ret = $c->init();
    is $ret, 0, 'init returns 0';
    is $render_specific_not_found, 1, 'specific 404 error rendered';
    is $render, 0, 'not rendering job state' or always_explain $render;
};

subtest edit => sub {
    my $app = Mojolicious->new();
    $app->attr('schema', sub { FakeSchema->new() });
    my $not_found;
    my $render_specific_not_found;
    my $found;
    monkey_patch 'OpenQA::Shared::Controller::Running', init => sub { 1 };
    monkey_patch 'FakeSchema::Find', find => sub { undef };
    monkey_patch 'OpenQA::Shared::Controller::Running', not_found => sub { $not_found = 1 };
    monkey_patch 'OpenQA::Shared::Controller::Running',
      render_specific_not_found => sub { $render_specific_not_found = 1 };
    monkey_patch 'OpenQA::Shared::Controller::Running', reply => sub { shift };

    # No results
    my $c = OpenQA::Shared::Controller::Running->new(app => $app);
    $c->param('testid', 'foobar');
    $c->stash('job', Job->new);
    $c->edit();
    is $render_specific_not_found, 1, 'No results';

    # Check if we can get the fake results
    my $details_count;
    monkey_patch 'FakeSchema::Find', find => sub { Job->new };
    monkey_patch 'OpenQA::Shared::Controller::Running', redirect_to => sub { $found = 1; $details_count = $_[5]; };
    $c = OpenQA::Shared::Controller::Running->new(app => $app);
    $c->param('testid', 'foobar');
    $c->stash('job', Job->new);
    $c->edit();
    is $found, 1, 'Redirecting to results';
    is $details_count, 3, 'Fake results are correct';
};

done_testing;

package Job;

sub new {
    my ($class) = @_;
    my $self = bless({}, $class);
    $self->{worker} = Worker->new;
    return $self;
}
sub id { 42 }
sub worker { shift->{worker} }
sub state { OpenQA::Jobs::Constants::RUNNING }
sub result { OpenQA::Jobs::Constants::NONE }
sub modules { FakeSchema::Find->new }
sub results { {details => [qw(foo bar baz)]} }
sub name { 'foobar' }

package Worker;
use Mojo::File 'tempdir';

sub new {
    my ($class) = @_;
    my $self = bless({}, $class);
    $self->{WORKER_TMPDIR} = tempdir;
    return $self;
}

sub id { 43 }
sub job_id { 42 }
sub get_property { shift->{WORKER_TMPDIR} }

package Mojo::Transaction::Fake;
use Mojo::Base 'Mojo::Transaction', -signatures;
sub resume { ++$_[0]{writing} and return $_[0]->emit('resume') }
sub connection { shift->{fakestream} }
sub remote_address { '::1' }
sub error { $fake_error }
sub finish ($self) { $self->emit(finish => $self) }

package FakeSchema;
use Mojo::Base -signatures;

sub new {
    my ($class) = @_;
    my $self = bless({}, $class);
    $self->{resultset} = Worker->new;
    return $self;
}

sub resultset ($self, $name) { FakeSchema::Find->new($name) }

package FakeSchema::Find;
use Mojo::Base -signatures;
sub new ($class, $name = '') { bless({name => $name}, $class) }
