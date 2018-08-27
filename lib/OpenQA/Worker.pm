# Copyright (C) 2015-2017 SUSE LLC
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

package OpenQA::Worker;
use 5.018;
use warnings;

use Mojolicious::Lite;
use Mojo::Server::Daemon;
use Mojo::IOLoop;

use File::Spec::Functions 'catdir';
use Mojo::File 'path';

use OpenQA::Client;
use OpenQA::Utils qw(log_error log_info log_debug);
use OpenQA::Worker::Common;
use OpenQA::Worker::Commands;
use OpenQA::Worker::Pool qw(lockit clean_pool);
use OpenQA::Worker::Jobs;
use OpenQA::Setup;

sub init {
    my ($host_settings, $options) = @_;
    $instance  = $options->{instance} if defined $options->{instance};
    $pooldir   = $OpenQA::Utils::prjdir . '/pool/' . $instance;
    $nocleanup = $options->{"no-cleanup"};

    my $logdir = $ENV{OPENQA_WORKER_LOGDIR} // $worker_settings->{LOG_DIR};
    my $app    = OpenQA::Setup->new(
        mode     => 'production',
        log_name => 'worker',
        instance => $instance,
        log_dir  => $logdir
    );

    $app->level($worker_settings->{LOG_LEVEL}) if $worker_settings->{LOG_LEVEL};
    $app->setup_log();
    OpenQA::Worker::Common::api_init($host_settings, $options);
    OpenQA::Worker::Engines::isotovideo::set_engine_exec($options->{isotovideo});
}

sub main {
    my ($host_settings) = @_;
    my $lockfd = lockit();
    my $dir;
    my $shared_cache;
    clean_pool();
    ## register worker at startup to all webuis
    for my $h (@{$host_settings->{HOSTS}}) {
        # check if host`s working directory exists
        # if caching is not enabled

        if ($worker_settings->{CACHEDIRECTORY}) {
            $shared_cache = prepare_cache_directory($h, $worker_settings->{CACHEDIRECTORY});
        }
        # this is being also duplicated by OpenQA::Test::Utils since 49c06362d
        my @dirs = ($host_settings->{$h}{SHARE_DIRECTORY}, catdir($OpenQA::Utils::prjdir, 'share'));
        ($dir) = grep { $_ && -d } @dirs;
        unless ($dir) {
            map { log_debug("Found possible working directory for $h: $_") if $_ } @dirs;
            log_error("Ignoring host '$h': Working directory does not exist.");
            next;
        }

        log_info("Project dir for host $h is $dir");
        Mojo::IOLoop->next_tick(
            sub {
                OpenQA::Worker::Common::register_worker($h, $dir, $host_settings->{$h}{TESTPOOLSERVER}, $shared_cache);
            });
    }

    # start event loop - this will block until stop is called
    Mojo::IOLoop->start;

    return 0;
}

sub prepare_cache_directory {
    my ($current_host, $cachedirectory) = @_;
    my $host_to_cache = Mojo::URL->new($current_host)->host || $current_host;
    die "No cachedir" unless $cachedirectory;
    my $shared_cache = File::Spec->catdir($cachedirectory, $host_to_cache);
    File::Path::make_path($shared_cache);
    log_info("CACHE: caching is enabled, setting up $shared_cache");

    # make sure the downloads are in the same file system - otherwise
    # asset->move_to becomes a bit more expensive than it should
    my $tmpdir = File::Spec->catdir($cachedirectory, 'tmp');
    File::Path::make_path($tmpdir);
    $ENV{MOJO_TMPDIR} = $tmpdir;

    return $shared_cache;
}

sub catch_exit {
    my ($sig) = @_;
    log_info("quit due to signal $sig");
    Mojo::IOLoop->singleton->emit('catch_exit');
    if ($job) {
        Mojo::IOLoop->next_tick(
            sub {
                stop_job('quit');
            });
    }
    else {
        Mojo::IOLoop->stop;
    }
}

$SIG{HUP}  = \*catch_exit;
$SIG{TERM} = \*catch_exit;
$SIG{INT}  = \*catch_exit;

1;
