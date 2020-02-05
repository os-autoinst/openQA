package OpenQA::Test::Utils;
use Mojo::Base -strict;

use Exporter 'import';
use IO::Socket::INET;
use Storable qw(lock_store lock_retrieve);
use Mojolicious;
use POSIX '_exit';
use OpenQA::Worker;
use Config::IniFiles;
use Data::Dumper 'Dumper';
use OpenQA::Utils qw(log_error log_info log_debug service_port);
use OpenQA::WebSockets;
use OpenQA::WebSockets::Client;
use OpenQA::Scheduler;
use OpenQA::Scheduler::Client;
use Mojo::Home;
use Mojo::File qw(path tempfile);
use Cwd qw(abs_path getcwd);
use Mojo::Util 'gzip';
use Test::More;
use Mojo::IOLoop;
use Mojo::IOLoop::ReadWriteProcess 'process';
use Mojo::Server::Daemon;
use Test::MockModule;
use Time::HiRes 'sleep';

BEGIN {
    if (!$ENV{MOJO_HOME}) {
        # override default home as Mojo gets it wrong for our sub apps
        # This 'require' is here because the 'home detect' method
        # relies on %INC, which is only populated when the module is
        # loaded: see #870 and #876
        require OpenQA::Utils;
        $ENV{MOJO_HOME} = Mojo::Home->new->detect('OpenQA::Utils');
    }
}

our (@EXPORT, @EXPORT_OK);
@EXPORT_OK = (
    qw(redirect_output standard_worker),
    qw(create_webapi create_websocket_server create_scheduler create_live_view_handler),
    qw(unresponsive_worker wait_for_worker setup_share_dir run_gru_job),
    qw(kill_service unstable_worker client_output fake_asset_server),
    qw(cache_minion_worker cache_worker_service shared_hash embed_server_for_testing)
);

sub cache_minion_worker {
    process(
        sub {

            # this service can be very noisy
            require OpenQA::CacheService;
            local $ENV{MOJO_MODE} = 'test';
            OpenQA::CacheService::run(qw(minion worker));
            Devel::Cover::report() if Devel::Cover->can('report');
            _exit(0);
        })->set_pipes(0)->separate_err(0)->blocking_stop(1)->channels(0);
}

sub cache_worker_service {
    process(
        sub {

            # this service can be very noisy
            require OpenQA::CacheService;
            local $ENV{MOJO_MODE} = 'test';
            my $port = service_port 'cache_service';
            OpenQA::CacheService::run('daemon', '-l', "http://*:$port");
            Devel::Cover::report() if Devel::Cover->can('report');
            _exit(0);
        })->set_pipes(0)->separate_err(0)->blocking_stop(1)->channels(0);
}

sub fake_asset_server {
    my $mock = Mojolicious->new;
    $mock->mode('test');
    my $r = $mock->routes;
    $r->get(
        '/test.gz' => sub {
            my $c       = shift;
            my $archive = gzip 'This file was compressed!';
            $c->render(data => $archive);
        });
    $r->get(
        '/tests/:job/asset/:type/:filename' => sub {
            my $c        = shift;
            my $id       = $c->stash('job');
            my $type     = $c->stash('type');
            my $filename = $c->stash('filename');
            return $c->render(status => 404, text => "Move along, nothing to see here")
              if $filename =~ /sle-12-SP3-x86_64-0368-404/;
            return $c->render(status => 400, text => "Move along, nothing to see here")
              if $filename =~ /sle-12-SP3-x86_64-0368-400/;
            return $c->render(status => 500, text => "Move along, nothing to see here")
              if $filename =~ /sle-12-SP3-x86_64-0368-500/;
            return $c->render(status => 503, text => "Move along, nothing to see here")
              if $filename =~ /sle-12-SP3-x86_64-0368-503/;

            if ($filename =~ /sle-12-SP3-x86_64-0368-589/) {
                $c->res->headers->content_length(10);
                $c->inactivity_timeout(1);
                $c->res->headers->content_type('text/plain');
                $c->res->body('Six!!!');
                $c->rendered(200);
            }

            elsif (my ($size) = ($filename =~ /sle-12-SP3-x86_64-0368-200_?([0-9]+)?\@/)) {
                my $our_etag = 'andi $a3, $t1, 41399';

                my $browser_etag = $c->req->headers->header('If-None-Match');
                if ($browser_etag && $browser_etag eq $our_etag) {
                    $c->res->body('');
                    $c->rendered(304);
                }
                else {
                    $c->res->headers->content_length($size // 1024);
                    $c->inactivity_timeout(1);
                    $c->res->headers->content_type('text/plain');
                    $c->res->headers->header('ETag' => $our_etag);
                    $c->res->body("\0" x ($size // 1024));
                    $c->rendered(200);
                }
            }

            elsif ($filename =~ /sle-12-SP3-x86_64-0368-200_client_error/) {
                $c->render(text => 'Client error!', status => 404);
            }

            elsif ($filename =~ /sle-12-SP3-x86_64-0368-200_server_error/) {
                $c->render(text => 'Server error!', status => 500);
            }

            elsif ($filename =~ /sle-12-SP3-x86_64-0368-200_close/) {
                my $stream = Mojo::IOLoop->stream($c->tx->connection);
                Mojo::IOLoop->next_tick(sub { $stream->close });
            }

            elsif ($filename =~ /sle-12-SP3-x86_64-0368-200_#:/) {
                $c->res->headers->content_length(20);
                $c->res->headers->content_type('text/plain');
                $c->res->headers->header('ETag' => '123456789');
                $c->res->body('this is a test for character check');
                $c->rendered(200);
            }
        });

    $mock->routes->get(
        '/' => sub {
            my $c = shift;
            return $c->render(status => 200, text => "server is running");
        });
    return $mock;
}

sub redirect_output {
    my ($buf) = @_;
    open my $FD, '>', $buf;
    *STDOUT = $FD;
    *STDERR = $FD;
}

sub kill_service {
    my ($pid, $forced) = @_;
    return unless $pid;
    kill POSIX::SIGTERM => $pid;
    kill POSIX::SIGKILL => $pid if $forced;
    waitpid($pid, 0);
}

sub wait_for_worker {
    my ($schema, $id) = @_;

    note("Waiting for worker with ID $id");
    for (0 .. 40) {
        sleep .5;
        my $worker = $schema->resultset('Workers')->find($id);
        return undef if defined $worker && !$worker->dead;
    }
    note("No worker with ID $id active");
}

sub create_webapi {
    my ($mojoport, $schema_hook) = @_;
    die 'No port specified '       unless $mojoport;
    die 'No schema hook specified' unless $schema_hook;
    note("Starting WebUI service. Port: $mojoport");

    my $mojopid = fork();
    if ($mojopid == 0) {
        log_info("inserting fixtures into database\n");
        $schema_hook->();

        local $ENV{MOJO_MODE} = 'test';
        my $daemon = Mojo::Server::Daemon->new(listen => ["http://127.0.0.1:$mojoport"], silent => 1);
        $daemon->build_app('OpenQA::WebAPI');
        $daemon->run;
        Devel::Cover::report() if Devel::Cover->can('report');
        _exit(0);
    }
    else {
        #$SIG{__DIE__} = sub { kill('TERM', $mojopid); };
        # as this might download assets on first test, we need to wait a while
        my $wait = time + 50;
        while (time < $wait) {
            my $t      = time;
            my $socket = IO::Socket::INET->new(
                PeerHost => '127.0.0.1',
                PeerPort => $mojoport,
                Proto    => 'tcp',
            );
            last    if $socket;
            sleep 1 if time - $t < 1;
        }
    }
    return $mojopid;
}

sub create_websocket_server {
    my ($port, $bogus, $nowait, $with_embedded_scheduler) = @_;

    note("Starting WebSocket service");
    note("Bogus: $bogus | No wait: $nowait");

    OpenQA::WebSockets::Client->singleton->port($port);
    my $wspid = fork();
    if ($wspid == 0) {
        local $ENV{MOJO_LISTEN}             = "http://127.0.0.1:$port";
        local $ENV{MOJO_INACTIVITY_TIMEOUT} = 9999;

        use OpenQA::WebSockets;
        use Mojo::Util 'monkey_patch';
        use OpenQA::WebSockets;
        use OpenQA::WebSockets::Controller::Worker;
        use OpenQA::WebSockets::Plugin::Helpers;

        # TODO: Kill it with fire!
        if ($bogus) {
            monkey_patch 'OpenQA::WebSockets::Controller::Worker', _get_worker => sub { return };
            monkey_patch 'OpenQA::WebSockets::Controller::Worker', ws          => sub {
                my $c = shift;
                $c->on(json   => \&OpenQA::WebSockets::Controller::Worker::_message);
                $c->on(finish => \&OpenQA::WebSockets::Controller::Worker::_finish);
            };
        }
        local @ARGV = ('daemon');

        # embed the scheduler REST API within the ws server (required for scheduler fullstack test)
        if ($with_embedded_scheduler) {
            note('Embedding scheduler within ws server subprocess');
            embed_server_for_testing(
                server_name => 'OpenQA::Scheduler',
                client      => OpenQA::Scheduler::Client->singleton,
                io_loop     => Mojo::IOLoop->singleton,
            );

            # mock the scheduler's automatic rescheduling behavior because this test invokes
            # the scheduling logic manually
            my $scheduler_mock = Test::MockModule->new('OpenQA::Scheduler');
            $scheduler_mock->mock(_reschedule => sub { });
        }

        OpenQA::WebSockets::run;
        Devel::Cover::report() if Devel::Cover->can('report');
        _exit(0);
    }
    elsif (!defined $nowait) {
        # wait for websocket server
        my $wait = time + 20;
        while (time < $wait) {
            my $t      = time;
            my $socket = IO::Socket::INET->new(
                PeerHost => '127.0.0.1',
                PeerPort => $port,
                Proto    => 'tcp'
            );
            last    if $socket;
            sleep 1 if time - $t < 1;
        }
    }
    return $wspid;
}

sub create_scheduler {
    my ($port, $no_stale_job_detection) = @_;

    note("Starting Scheduler service");

    OpenQA::Scheduler::Client->singleton->port($port);
    my $pid = fork();
    if ($pid == 0) {
        local $ENV{MOJO_LISTEN}             = "http://127.0.0.1:$port";
        local $ENV{MOJO_INACTIVITY_TIMEOUT} = 9999;
        local @ARGV                         = ('daemon');
        monkey_patch 'OpenQA::Scheduler::Model::Jobs', incomplete_and_duplicate_stale_jobs => sub { 1 }
          if $no_stale_job_detection;
        OpenQA::Scheduler::run;
        Devel::Cover::report() if Devel::Cover->can('report');
        _exit(0);
    }
    return $pid;
}

sub create_live_view_handler {
    my ($mojoport) = @_;
    my $pid = fork();
    if ($pid == 0) {
        my $livehandlerport = $mojoport + 2;
        my $daemon          = Mojo::Server::Daemon->new(listen => ["http://127.0.0.1:$livehandlerport"], silent => 1);
        $daemon->build_app('OpenQA::LiveHandler');
        $daemon->run;
        Devel::Cover::report() if Devel::Cover->can('report');
        _exit(0);
    }
    return $pid;
}

sub setup_share_dir {
    my ($sharedir) = @_;
    $sharedir = path($sharedir, 'openqa', 'share')->make_path;

    path($sharedir, 'factory', 'iso')->make_path;

    my $iso_file_path = abs_path('../os-autoinst/t/data/Core-7.2.iso') or die 'Core-7.2.iso not found';
    my $iso_link_path = path($sharedir, 'factory', 'iso')->child('Core-7.2.iso')->to_string();
    symlink($iso_file_path, $iso_link_path) || die "can't symlink $iso_link_path -> $iso_file_path";

    path($sharedir, 'tests')->make_path;

    my $tests_dir_path  = abs_path('../os-autoinst/t/data/tests/') or die 'tests dir not found';
    my $tests_link_path = path($sharedir, 'tests')->child('tinycore');
    symlink($tests_dir_path, $tests_link_path) || die "can't symlink $tests_link_path -> $tests_dir_path";

    return $sharedir;
}

sub unstable_worker {
    # the help of the Doctor would be really appreciated here.
    my ($apikey, $apisecret, $host, $instance, $ticks, $sleep) = @_;
    note("Starting unstable worker. Instance: $instance for host $host");
    $ticks = 1 unless defined $ticks;

    my $pid = fork();
    if ($pid == 0) {
        my $worker = OpenQA::Worker->new(
            {
                apikey    => $apikey,
                apisecret => $apisecret,
                instance  => $instance,
                verbose   => 1
            });
        $worker->settings->clear_webui_hosts;
        $worker->settings->add_webui_host($host);
        $worker->log_setup_info;
        $worker->init();
        if ($ticks < 0) {
            Mojo::IOLoop->singleton->start;
        }
        else {
            Mojo::IOLoop->singleton->one_tick for (0 .. $ticks);
        }
        Devel::Cover::report() if Devel::Cover->can('report');
        if ($sleep) {
            1 while sleep $sleep;
        }
        _exit(0);
    }
    sleep $sleep if $sleep;

    return $pid;
}

sub standard_worker {
    my ($apikey, $apisecret, $host, $instance) = @_;

    note("Starting standard worker. Instance: $instance for host $host");
    c_worker($apikey, $apisecret, $host, $instance, 0);
}
sub unresponsive_worker {
    my ($apikey, $apisecret, $host, $instance) = @_;

    note("Starting unresponsive worker. Instance: $instance for host $host");
    c_worker($apikey, $apisecret, $host, $instance, 1);
}

sub c_worker {
    my ($apikey, $apisecret, $host, $instance, $bogus) = @_;
    $bogus //= 1;

    my $pid = fork();
    if ($pid == 0) {
        my $command_handler_mock = Test::MockModule->new('OpenQA::Worker::CommandHandler');
        if ($bogus) {
            $command_handler_mock->mock(
                handle_command => sub {
                    my ($self, $tx, $json) = @_;
                    log_debug('Received ws message: ' . Dumper($json));
                });
        }

        my $worker = OpenQA::Worker->new(
            {
                apikey    => $apikey,
                apisecret => $apisecret,
                instance  => $instance,
                verbose   => 1
            });
        $worker->settings->clear_webui_hosts;
        $worker->settings->add_webui_host($host);
        $worker->log_setup_info;
        $worker->exec();

        Devel::Cover::report() if Devel::Cover->can('report');
        _exit(0);
    }

    return $pid;
}

sub client_output {
    my ($apikey, $apisecret, $host, $args) = @_;
    my $connect_args = "--apikey=${apikey} --apisecret=${apisecret} --host=${host}";
    open(my $client, "perl ./script/client $connect_args $args|");
    my $out;
    while (<$client>) {
        $out .= $_;
    }
    close($client);
    return $out;
}

sub shared_hash {
    my $hash = shift;
    state $file = do { my $f = tempfile; lock_store {}, $f->to_string; $f };
    return lock_retrieve $file->to_string unless $hash;
    lock_store $hash, $file->to_string;
}

sub embed_server_for_testing {
    my (%args)      = @_;
    my $server_name = $args{server_name};
    my $client      = $args{client};

    # change the client to use an embedded server for testing (this avoids
    # forking a second process)
    my $server = $client->{test_server};
    unless ($server) {
        $server = $client->{test_server} = Mojo::Server::Daemon->new(
            ioloop => ($args{io_loop} // $client->client->ioloop),
            listen => ($args{listen}  // ['http://127.0.0.1']),
            silent => ($args{silent}  // 1),
        );
        $server->build_app($server_name)->mode($args{mode} // 'production');
        $server->start;
        $client->port($server->ports->[0]);
    }

    return $server;
}

sub run_gru_job {
    my $app    = shift;
    my $id     = $app->gru->enqueue(@_)->{minion_id};
    my $worker = $app->minion->worker->register;
    my $job    = $worker->dequeue(0, {id => $id});
    $job->perform;
    $worker->unregister;
    return $job->info;
}

1;
