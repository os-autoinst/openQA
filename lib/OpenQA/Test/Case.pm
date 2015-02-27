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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::Test::Case;

use OpenQA::Test::Database;
use OpenQA::Test::Testresults;
use OpenQA::Schema::Result::Users;
use Mojo::Base -base;
use Date::Format qw/time2str/;
use Mojo::JSON 'j';
use Mojo::Util qw(b64_decode b64_encode hmac_sha1_sum);

sub new {
    my $self = shift->SUPER::new;

    $ENV{OPENQA_CONFIG} = 't/data';

    return $self;
}

{

    my $schema;

    sub init_data {
        # This should result in the 't' directory, even if $0 is in a subdirectory
        my ($tdirname) = $0 =~ qr/((.*\/t\/|^t\/)).+$/;
        $schema = OpenQA::Test::Database->new->create();

        # ARGL, we can't fake the current time and the db manages
        # t_started so we have to override it manually
        my $r = $schema->resultset("Jobs")->search({ id => 99937 })->update(
            {
                t_created => time2str('%Y-%m-%d %H:%M:%S', time-540000, 'UTC'),  # 150 hours ago;
            }
        );

        OpenQA::Test::Testresults->new->create(directory => $tdirname.'testresults');
    }

    sub login {
        my ($self, $test, $username) = @_;
        # Used to sign the cookie after modifying it
        my $secret = $test->app->secrets->[0];

        # Look for the signed cookie
        if (my $jar = $test->ua->cookie_jar) {
            my $cookie;
            if (ref($jar->all) eq 'ARRAY') {
                $cookie = $jar->all->[0];
            }
            else {
                my @cookies = $jar->all;
                $cookie = $cookies[0];
            }

            # Extract the information...
            my ($value) = split('--', $cookie->value);
            $value = j(b64_decode($value));
            # ..add the user value...
            OpenQA::Schema::Result::Users->create_user($username, $schema);
            $value->{user} = $username;
            # ...and sign the cookie again with the new value
            $value = b64_encode(j($value), '');
            $value =~ y/=/-/;
            # make login cookie only valid for https
            # XXX_: we can't do this because the test server runs on
            # http so the Mojo useragent doesn't use the cookie
            #$cookie->secure(1);
            $cookie->value("$value--".hmac_sha1_sum($value, $secret));
        }

        return 1;
    }

}

1;
# vim: set sw=4 et:
