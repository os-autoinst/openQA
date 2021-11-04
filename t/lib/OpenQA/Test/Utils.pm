package OpenQA::Test::Utils;
use Test::Most;
use Mojo::Base -base, -signatures;

use Exporter 'import';
use FindBin;
use IO::Socket::INET;
use Storable qw(lock_store lock_retrieve);
use Mojolicious;
use POSIX qw(_exit WNOHANG);
use OpenQA::Worker;
use Config::IniFiles;
use Data::Dumper 'Dumper';
use OpenQA::App;
use OpenQA::Constants 'DEFAULT_WORKER_TIMEOUT';
use OpenQA::Log qw(log_error log_info log_debug);
use OpenQA::Utils 'service_port';
use OpenQA::WebSockets;
use OpenQA::WebSockets::Client;
use OpenQA::Scheduler;
use OpenQA::Scheduler::Client;
use Mojo::Home;
use Mojo::File qw(path tempfile tempdir);
use Mojo::Util 'dumper';
use Cwd qw(abs_path getcwd);
use IPC::Run qw(start);
use Mojolicious;
use Mojo::Util 'gzip';
use Test::Output 'combined_like';
use Mojo::IOLoop;
use Mojo::IOLoop::ReadWriteProcess 'process';
use Mojo::Server::Daemon;
use Mojo::IOLoop::Server;
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
    qw(mock_service_ports setup_mojo_app_with_default_worker_timeout),
    qw(redirect_output create_user_for_workers),
    qw(create_webapi create_websocket_server create_scheduler create_live_view_handler),
    qw(unresponsive_worker broken_worker rejective_worker setup_share_dir setup_fullstack_temp_dir run_gru_job),
    qw(stop_service start_worker unstable_worker fake_asset_server),
    qw(cache_minion_worker cache_worker_service shared_hash embed_server_for_testing),
    qw(run_cmd test_cmd wait_for wait_for_or_bail_out perform_minion_jobs),
    qw(prepare_clean_needles_dir prepare_default_needle mock_io_loop assume_all_assets_exist)
);

# The function OpenQA::Utils::service_port method hardcodes ports in a
# sequential range starting with OPENQA_BASE_PORT. This can cause problems
# especially in repeated testing if any of the ports in that range is already
# occupied. So we inject random, free ports for the services here.
#
# Potential point for later improvement: In
# Mojo::IOLoop::Server::generate_port keep the sock object on the port and
# reuse it in listen to prevent race condition
#
# Potentially this approach can also be used in production code.

sub mock_service_ports {
    my %ports;
    Test::MockModule->new('OpenQA::Utils')->redefine(
        service_port => sub {
            my ($service) = @_;
            my $port = $ports{$service} //= Mojo::IOLoop::Server->generate_port;
            note("Mocking service port for $service to be $port");
            return $port;
        });
    note('Used ports: ' . dumper(\%ports));
}

sub setup_mojo_app_with_default_worker_timeout {
    OpenQA::App->set_singleton(
        Mojolicious->new(config => {global => {worker_timeout => DEFAULT_WORKER_TIMEOUT}}, log => undef));
}

sub cache_minion_worker {
    process(
        sub {

            # this service can be very noisy
            require OpenQA::CacheService;
            local $ENV{MOJO_MODE} = 'test';
            note('Starting cache minion worker');
            OpenQA::CacheService::run(qw(run));
            note('Cache minion worker stopped');
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
            note("Starting worker cache service on port $port");
            OpenQA::CacheService::run('daemon', '-l', "http://*:$port");
            note("Worker cache service on port $port stopped");
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
            my $c = shift;
            my $archive = gzip 'This file was compressed!';
            $c->render(data => $archive);
        });
    $r->get(
        '/test' => sub {
            my $c = shift;
            $c->render(text => 'This file was not compressed!', format => 'txt');
        });
    $r->get(
        '/tests/:job/asset/:type/*filename' => sub {
            my $c = shift;
            my $id = $c->stash('job');
            my $type = $c->stash('type');
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

# define internal helper functions to keep track of Perl warnings produced by sub processes spawned by
# the subsequent create_…-functions
sub _setup_sub_process {
    # log the PID of the sub process and exit immediately when a Perl warning occurs
    # note: This function is supposed to be called from within the sub process.
    my ($process_name) = @_;
    $0 = $process_name;
    note "PID of $process_name: $$";
    $SIG{__WARN__} = sub {
        log_error "Stopping $process_name process because a Perl warning occurred: @_";
        _exit 42;
    };
}
sub _fail_and_exit { fail shift; done_testing; exit shift }
my %RELEVANT_CHILD_PIDS;
my $SIGCHLD_HANDLER = sub {
    # produces a test failure in case any relevant sub process terminated with a non-zero exit code
    # note: This function is supposed to be called from the SIGCHLD handler. It seems to have no effect to
    #       call die or BAIL_OUT from that handler so fail and _exit is used instead.
    while ((my $pid = waitpid(-1, WNOHANG)) > 0) {
        my $exit_code = $?;
        next unless my $child_name = delete $RELEVANT_CHILD_PIDS{$pid};
        _fail_and_exit "sub process $child_name terminated with exit code $exit_code", $exit_code if $exit_code;
    }
};
sub _pids_from_ipc_run_harness {
    my ($ipc_run_harness, $error_message) = @_;
    my $children = ref $ipc_run_harness->{KIDS} eq 'ARRAY' ? $ipc_run_harness->{KIDS} : [];
    my @pids = map { ref $_ eq 'HASH' ? ($_->{PID}) : () } @$children;
    BAIL_OUT($error_message) if $error_message && !@pids;
    return \@pids;
}
sub _setup_sigchld_handler {
    # adds the PIDs from the specified $ipc_run_harness to the PIDs considered by $SIGCHLD_HANDLER and
    # ensures $SIGCHLD_HANDLER is called
    my ($child_name, $ipc_run_harness) = @_;
    $RELEVANT_CHILD_PIDS{$_} = $child_name
      for @{_pids_from_ipc_run_harness($ipc_run_harness, "IPC harness for $child_name contains no PIDs")};
    $SIG{CHLD} = $SIGCHLD_HANDLER;
    return $ipc_run_harness;
}

sub stop_service {
    my ($h, $forced) = @_;
    return unless $h;

    delete $RELEVANT_CHILD_PIDS{$_} for @{_pids_from_ipc_run_harness($h)};
    if ($forced) {
        $h->kill_kill(grace => 3);
    }
    else {
        $h->signal('TERM');
    }
    $h->finish;
}

sub create_webapi ($port = undef, $no_cover = undef) {
    $port //= service_port 'webui';
    note("Starting WebUI service. Port: $port");

    my $h = _setup_sigchld_handler 'openqa-webapi', start sub {
        _setup_sub_process 'openqa-webapi';
        local $ENV{MOJO_MODE} = 'test';

        my $daemon = Mojo::Server::Daemon->new(listen => ["http://127.0.0.1:$port"], silent => 1);
        $daemon->build_app('OpenQA::WebAPI');
        $daemon->run;
        Devel::Cover::report() if !$no_cover && Devel::Cover->can('report');
    };
    # as this might download assets on first test, we need to wait a while
    my $wait = time + 50;
    while (time < $wait) {
        my $t = time;
        my $socket = IO::Socket::INET->new(
            PeerHost => '127.0.0.1',
            PeerPort => $port,
            Proto => 'tcp',
        );
        last if $socket;
        sleep 1 if time - $t < 1;
    }
    return $h;
}

sub create_websocket_server {
    my ($port, $bogus, $nowait, $with_embedded_scheduler, $no_cover) = @_;
    $port //= service_port 'websocket';

    note("Starting WebSocket service. Port: $port");
    note("Bogus: $bogus | No wait: $nowait");

    OpenQA::WebSockets::Client->singleton->port($port);
    my $h = _setup_sigchld_handler 'openqa-websocket', start sub {
        _setup_sub_process 'openqa-websocket';
        local $ENV{MOJO_LISTEN} = "http://127.0.0.1:$port";
        local $ENV{MOJO_INACTIVITY_TIMEOUT} = 9999;

        use OpenQA::WebSockets;
        use Mojo::Util 'monkey_patch';
        use OpenQA::WebSockets;
        use OpenQA::WebSockets::Controller::Worker;
        use OpenQA::WebSockets::Plugin::Helpers;

        if ($bogus) {
            monkey_patch 'OpenQA::WebSockets::Controller::Worker', _get_worker => sub { return };
            monkey_patch 'OpenQA::WebSockets::Controller::Worker', ws => sub {
                my $c = shift;
                $c->on(json => \&OpenQA::WebSockets::Controller::Worker::_message);
                $c->on(finish => \&OpenQA::WebSockets::Controller::Worker::_finish);
            };
        }
        local @ARGV = ('daemon');

        # embed the scheduler REST API within the ws server (required for scheduler fullstack test)
        if ($with_embedded_scheduler) {
            note('Embedding scheduler within ws server subprocess');
            embed_server_for_testing(
                server_name => 'OpenQA::Scheduler',
                client => OpenQA::Scheduler::Client->singleton,
                io_loop => Mojo::IOLoop->singleton,
            );

            # mock the scheduler's automatic rescheduling behavior because this test invokes
            # the scheduling logic manually
            my $scheduler_mock = Test::MockModule->new('OpenQA::Scheduler');
            $scheduler_mock->redefine(_reschedule => sub { });
        }

        OpenQA::WebSockets::run;
        Devel::Cover::report() if !$no_cover && Devel::Cover->can('report');
    };
    if (!defined $nowait) {
        # wait for websocket server
        my $limit = 20;
        my $wait = time + $limit;
        while (time < $wait) {
            my $t = time;
            my $socket = IO::Socket::INET->new(
                PeerHost => '127.0.0.1',
                PeerPort => $port,
                Proto => 'tcp'
            );
            last if $socket;
            sleep 1 if time - $t < 1;
        }
        die("websocket server is not responsive after '$limit' seconds") unless time < $wait;
    }
    return $h;
}

sub create_scheduler ($port = service_port 'scheduler') {
    note("Starting Scheduler service. Port: $port");
    OpenQA::Scheduler::Client->singleton->port($port);
    _setup_sigchld_handler 'openqa-scheduler', start sub {
        _setup_sub_process 'openqa-scheduler';
        local $ENV{MOJO_LISTEN} = "http://127.0.0.1:$port";
        local $ENV{MOJO_INACTIVITY_TIMEOUT} = 9999;
        local @ARGV = ('daemon');
        OpenQA::Scheduler::run;
        Devel::Cover::report() if Devel::Cover->can('report');
    };
}

sub create_live_view_handler {
    my ($port) = @_;
    $port //= service_port 'livehandler';
    _setup_sigchld_handler 'openqa-livehandler', start sub {
        _setup_sub_process 'openqa-livehandler';
        my $daemon = Mojo::Server::Daemon->new(listen => ["http://127.0.0.1:$port"], silent => 1);
        $daemon->build_app('OpenQA::LiveHandler');
        $daemon->run;
        Devel::Cover::report() if Devel::Cover->can('report');
    };
}

sub setup_share_dir {
    my ($sharedir) = @_;
    $sharedir = path($sharedir, 'openqa', 'share')->make_path;

    path($sharedir, 'factory', 'iso')->make_path;

    my $iso_file_path = abs_path('../os-autoinst/t/data/Core-7.2.iso') or die 'Core-7.2.iso not found';
    my $iso_link_path = path($sharedir, 'factory', 'iso')->child('Core-7.2.iso')->to_string();
    symlink($iso_file_path, $iso_link_path) || die "can't symlink $iso_link_path -> $iso_file_path";

    path($sharedir, 'tests')->make_path;

    my $tests_dir_path = abs_path('../os-autoinst/t/data/tests/') or die 'tests dir not found';
    my $tests_link_path = path($sharedir, 'tests')->child('tinycore');
    symlink($tests_dir_path, $tests_link_path) || die "can't symlink $tests_link_path -> $tests_dir_path";

    return $sharedir;
}

sub setup_fullstack_temp_dir {
    my ($test_name) = @_;
    my $tempdir = $ENV{OPENQA_FULLSTACK_TEMP_DIR} ? path($ENV{OPENQA_FULLSTACK_TEMP_DIR}) : tempdir;
    my $basedir = $tempdir->child($test_name);
    my $configdir = path($basedir, 'config')->make_path;
    my $datadir = path($FindBin::Bin, 'data');

    $datadir->child($_)->copy_to($configdir->child($_)) for qw(openqa.ini database.ini workers.ini);
    path($basedir, 'openqa', 'db')->make_path->child('db.lock')->spurt;

    note("OPENQA_BASEDIR: $basedir\nOPENQA_CONFIG: $configdir");
    $ENV{OPENQA_BASEDIR} = $basedir;
    $ENV{OPENQA_CONFIG} = $configdir;
    return $tempdir;
}

sub create_user_for_workers {
    my $schema = OpenQA::Schema->singleton;
    my $user = $schema->resultset('Users')->create({username => 'worker', is_operator => 1, is_admin => 1});
    return $schema->resultset('ApiKeys')->create({user_id => $user->id});
}

sub setup_worker {    # uncoverable statement
    my ($worker, $host) = @_;    # uncoverable statement

    $worker->settings->webui_hosts([]);    # uncoverable statement
    $worker->settings->webui_host_specific_settings({});    # uncoverable statement
    push(@{$worker->settings->webui_hosts}, $host);    # uncoverable statement
    $worker->settings->webui_host_specific_settings->{$host} = {};    # uncoverable statement
    $worker->log_setup_info;    # uncoverable statement
}

sub start_worker {
    my ($connect_args) = @_;
    my $os_autoinst_path = '../os-autoinst';
    my $isotovideo_path = $os_autoinst_path . '/isotovideo';

    # save testing time as we do not test a webUI host being down for
    # multiple minutes
    $ENV{OPENQA_WORKER_CONNECT_RETRIES} = 1;
    # enable additional diagnostics for serialization errors
    $ENV{DEBUG_JSON} = 1;
    my @cmd = qw(perl ./script/worker --isotovideo=../os-autoinst/isotovideo --verbose);
    push @cmd, @$connect_args;
    start \@cmd;
}

sub unstable_worker {
    # the help of the Doctor would be really appreciated here.
    my ($apikey, $apisecret, $host, $instance, $ticks, $sleep) = @_;
    note("Starting unstable worker. Instance: $instance for host $host");
    $ticks = 1 unless defined $ticks;

    my $h = _setup_sigchld_handler 'openqa-worker-unstable', start sub {    # uncoverable statement
        _setup_sub_process 'openqa-worker-unstable';    # uncoverable statement
        my $worker = OpenQA::Worker->new(    # uncoverable statement
            {    # uncoverable statement
                apikey => $apikey,    # uncoverable statement
                apisecret => $apisecret,    # uncoverable statement
                instance => $instance,    # uncoverable statement
                verbose => 1    # uncoverable statement
            });    # uncoverable statement
        setup_worker($worker, $host);    # uncoverable statement
        $worker->init();    # uncoverable statement
        if ($ticks < 0) {    # uncoverable statement
            Mojo::IOLoop->singleton->start;    # uncoverable statement
        }    # uncoverable statement
        else {    # uncoverable statement
            Mojo::IOLoop->singleton->one_tick for (0 .. $ticks);    # uncoverable statement
        }    # uncoverable statement
        Devel::Cover::report() if Devel::Cover->can('report');    # uncoverable statement
        if ($sleep) {    # uncoverable statement
            1 while sleep $sleep;    # uncoverable statement
        }    # uncoverable statement
    };
    sleep $sleep if $sleep;
    return $h;
}

sub unresponsive_worker {
    my ($apikey, $apisecret, $host, $instance) = @_;

    note("Starting unresponsive worker. Instance: $instance for host $host");
    c_worker($apikey, $apisecret, $host, $instance, 1);
}
sub broken_worker {
    my ($apikey, $apisecret, $host, $instance, $error) = @_;

    note("Starting broken worker. Instance: $instance for host $host");
    c_worker($apikey, $apisecret, $host, $instance, 0, error => $error);
}
sub rejective_worker {
    my ($apikey, $apisecret, $host, $instance, $reason) = @_;

    note("Starting rejective worker. Instance: $instance for host $host");
    c_worker($apikey, $apisecret, $host, $instance, 1, rejection_reason => $reason);
}

sub c_worker {
    my ($apikey, $apisecret, $host, $instance, $bogus, %options) = @_;
    $bogus //= 1;

    _setup_sigchld_handler 'openqa-worker', start sub {
        _setup_sub_process 'openqa-worker';
        my $command_handler_mock = Test::MockModule->new('OpenQA::Worker::CommandHandler');
        if ($bogus) {
            $command_handler_mock->redefine(
                handle_command => sub {
                    my ($self, $tx, $json) = @_;
                    log_debug('Received ws message: ' . Dumper($json));

                    # if we've got a single job ID and a rejection reason simulate a worker
                    # which rejects the job
                    my $rejection_reason = $options{rejection_reason};
                    return undef unless defined $rejection_reason;
                    my $job_id = $json->{job}->{id};
                    return undef unless defined $job_id;
                    log_debug("Rejecting job $job_id");
                    $self->client->reject_jobs([$job_id], $rejection_reason);
                });
        }
        my $error = $options{error};
        my $worker_mock = Test::MockModule->new('OpenQA::Worker');
        $worker_mock->redefine(check_availability => $error) if defined $error;
        my $worker = OpenQA::Worker->new(
            {
                apikey => $apikey,
                apisecret => $apisecret,
                instance => $instance,
                verbose => 1
            });
        $worker->current_error($error) if defined $error;
        setup_worker($worker, $host);
        $worker->exec();

        Devel::Cover::report() if Devel::Cover->can('report');
    };
}

sub shared_hash {
    my $hash = shift;
    state $file = do { my $f = tempfile; lock_store {}, $f->to_string; $f };
    return lock_retrieve $file->to_string unless $hash;
    lock_store $hash, $file->to_string;
}

sub embed_server_for_testing {
    my (%args) = @_;
    my $server_name = $args{server_name};
    my $client = $args{client};

    # change the client to use an embedded server for testing (this avoids
    # forking a second process)
    my $server = $client->{test_server};
    unless ($server) {
        $server = $client->{test_server} = Mojo::Server::Daemon->new(
            ioloop => ($args{io_loop} // $client->client->ioloop),
            listen => ($args{listen} // ['http://127.0.0.1']),
            silent => ($args{silent} // 1),
        );
        $server->build_app($server_name)->mode($args{mode} // 'production');
        $server->start;
        $client->port($server->ports->[0]);
    }

    return $server;
}

sub run_gru_job {
    my $app = shift;
    my $id = $app->gru->enqueue(@_)->{minion_id};
    my $worker = $app->minion->worker->register;
    my $job = $worker->dequeue(0, {id => $id});
    my $err;
    defined($err = $job->execute) ? $job->fail($err) : $job->finish;
    $worker->unregister;
    return $job->info;
}

sub perform_minion_jobs ($minion, @args) {
    if ($ENV{TEST_FORK_MINION_JOBS}) { $minion->perform_jobs(@args) }
    else { $minion->perform_jobs_in_foreground(@args) }
}

sub run_cmd {
    my ($cmd, $args, $prefix) = @_;
    $args //= '';
    $prefix = $prefix ? $prefix . ' ' : '';
    my $complete_cmd = "$prefix $cmd $args";
    note("Calling '$complete_cmd'");
    system("$complete_cmd") >> 8;
}

sub test_cmd {
    my ($cmd, $args, $expected, $test_msg, $exit_code, $exit_code_msg) = @_;

    # Report failure at the callsite instead of the test function
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    $expected //= qr//;
    $test_msg //= 'command line is correct';
    $exit_code //= 0;
    $exit_code_msg //= 'command exits successfully';
    my $ret;
    combined_like { $ret = run_cmd($cmd, $args) } $expected, $test_msg;
    $exit_code eq 'non-zero' ? (isnt $ret, 0, $exit_code_msg) : (is $ret, $exit_code, $exit_code_msg);
    return $ret;
}

sub wait_for : prototype(&*;*) {    # `&*;*` allows calling it like `wait_for { 1 } 'foo'`
    my ($function, $description, $args) = @_;
    my $timeout = $args->{timeout} // 60;
    my $interval = $args->{interval} // .1;

    note "Waiting for '$description' to become available";
    while ($timeout > 0) {
        return 1 if $function->();
        $timeout -= sleep $interval;    # uncoverable statement (function might return early one line up)
    }
    return 0;    # uncoverable statement (only invoked if tests would fail)
}

sub wait_for_or_bail_out : prototype(&*;*) {    # `&*;*` allows calling it like `wait_for_or_bail_out { 1 } 'foo'`
    my ($function, $description, $args) = @_;
    wait_for \&$function, $description, $args or BAIL_OUT "'$description' not available";
}

sub prepare_clean_needles_dir ($dir = 't/data/openqa/share/tests/opensuse/needles') {
    return path($dir)->remove_tree->make_path;
}

sub prepare_default_needle ($dir) {
    my $dest = path($dir, 'inst-timezone-text.json');
    path('t/data/default-needle.json')->copy_to($dest);
    return $dest;
}

sub mock_io_loop (%args) {
    my $io_loop_mock = Test::MockModule->new('Mojo::IOLoop');
    $io_loop_mock->redefine(    # avoid forking to prevent coverage analysis from slowing down the test significantly
        subprocess => sub ($io_loop, $function, $callback) {
            my @result = eval { $function->() };
            my $error = $@;
            $io_loop->next_tick(sub { $callback->(undef, $error, @result) });
        }) if $args{subprocess};
    return $io_loop_mock;
}

sub assume_all_assets_exist { OpenQA::Schema->singleton->resultset('Assets')->search({})->update({size => 0}) }

1;
