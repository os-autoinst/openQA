# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

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
