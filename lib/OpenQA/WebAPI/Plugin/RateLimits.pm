# Copyright (C) 2021 SUSE LLC
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

package OpenQA::WebAPI::Plugin::RateLimits;
use Mojo::Base 'Mojolicious::Plugin', -signatures;


use Time::Seconds;

sub register ($self, $app, $conf) {
    $app->hook(
        around_action => sub ($next, $c, $action, $last) {
            return $next->() unless $last;
            # Allow n queries per minute, per user (if logged in)
            my $route = $c->current_route;
            # Only handle named routes with an explicit limit
            if ($route && (my $limit = $c->app->config->{rate_limits}{$route})) {
                my $lockname = "webui_${route}_rate_limit";
                if (my $user = $c->current_user) { $lockname .= $user->username }
                my $error = "Rate limit exceeded";
                return $c->respond_to(
                    json => {json     => {error => $error}, status => 429},
                    html => {template => 'layouts/rate_limit_error', limit => $limit, status => 429},
                ) unless $c->app->minion->lock($lockname, ONE_MINUTE, {limit => $limit});
            }
            return $next->();
        });
}

1;
