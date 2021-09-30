# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Test::Case;
use Mojo::Base -base;

use OpenQA::Test::Database;
use OpenQA::Test::Testresults;
use OpenQA::Schema::Result::Users;
use OpenQA::Schema;
use Date::Format 'time2str';
use Mojo::JSON 'decode_json';

sub new {
    my ($class, %options) = @_;
    my $self = $class->SUPER::new;

    $ENV{OPENQA_CONFIG} = $options{config_directory} // 't/data';

    return $self;
}

sub init_data {
    my ($self, %options) = @_;

    my $schema = OpenQA::Test::Database->new->create(%options);

    # This should result in the 't' directory, even if $0 is in a subdirectory
    my ($tdirname) = $0 =~ qr/((.*\/t\/|^t\/)).+$/;
    OpenQA::Test::Testresults->new->create(directory => $tdirname . 'testresults');
    return $schema;
}

sub login {
    my ($self, $test, $username) = @_;

    my $app = $test->app;
    my $sessions = $app->sessions;
    my $c = $app->build_controller;
    my $name = $sessions->cookie_name;
    return 0 unless my $cookie = (grep { $_->name eq $name } @{$test->ua->cookie_jar->all})[0];

    # Hack the existing session cookie and add a user to pretend we logged in
    $c->req->cookies($cookie);
    $sessions->load($c);
    OpenQA::Schema->singleton->resultset('Users')->create_user($username);
    $c->session->{user} = $username;
    $sessions->store($c);
    $cookie->value($c->res->cookie($name)->value);

    return 1;
}

## test helpers
sub trim_whitespace {
    my ($str) = @_;
    return $str =~ s/\s+/ /gr =~ s/(^\s)|(\s$)//gr;
}

sub find_most_recent_event {
    my ($schema, $event) = @_;

    my $result
      = $schema->resultset('AuditEvents')->find({event => $event}, {rows => 1, order_by => {-desc => 'id'}});
    return undef unless $result;
    return decode_json($result->event_data);
}

1;
