# Copyright (C) 2014 SUSE Linux Products GmbH
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

    # This should result in the 't' directory, even if $0 is in a subdirectory
    my ($tdirname) = $0 =~ qr/((.*\/t\/|^t\/)).+$/;
    my $schema = OpenQA::Test::Database->new->create(%options);

    # ARGL, we can't fake the current time and the db manages
    # t_started so we have to override it manually
    my $r = $schema->resultset("Jobs")->search({id => 99937})->update(
        {
            t_created => time2str('%Y-%m-%d %H:%M:%S', time - 540000, 'UTC'),    # 150 hours ago;
        });

    OpenQA::Test::Testresults->new->create(directory => $tdirname . 'testresults');
    return $schema;
}

sub login {
    my ($self, $test, $username) = @_;

    my $app      = $test->app;
    my $sessions = $app->sessions;
    my $c        = $app->build_controller;
    my $name     = $sessions->cookie_name;
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

    my $results
      = $schema->resultset('AuditEvents')->search({event => $event}, {limit => 1, order_by => {-desc => 'id'}});
    return undef unless $results;
    if (my $result = $results->next) {
        return decode_json($result->event_data);
    }
    return undef;
}

1;
