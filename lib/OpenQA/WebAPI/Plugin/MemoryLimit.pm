# Copyright 2018 SUSE LLC
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

package OpenQA::WebAPI::Plugin::MemoryLimit;
use Mojo::Base 'Mojolicious::Plugin';

use BSD::Resource 'getrusage';
use Mojo::IOLoop;

# Stop prefork workers gracefully once they reach a certain size
sub register {
    my ($self, $app) = @_;

    my $max = $app->config->{global}{max_rss_limit};
    return unless $max && $max > 0;

    my $parent = $$;
    Mojo::IOLoop->next_tick(
        sub {
            Mojo::IOLoop->recurring(
                5 => sub {
                    my $rss = (getrusage())[2];
                    # RSS is in KB under Linux
                    return unless $rss > $max;
                    $app->log->debug(qq{Worker exceeded RSS limit "$rss > $max", restarting});
                    Mojo::IOLoop->stop_gracefully;
                }) if $parent ne $$;
        });
}

1;
