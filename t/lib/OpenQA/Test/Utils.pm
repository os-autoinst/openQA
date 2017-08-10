package OpenQA::Test::Utils;
use base 'Exporter';
use IO::Socket::INET;
use Mojolicious;
use POSIX '_exit';
use OpenQA::Worker;
use OpenQA::Worker::Common;
use Config::IniFiles;
use File::Spec::Functions 'catdir';
use OpenQA::Utils qw(log_error log_info log_debug);
#use OpenQA::Worker::Pool qw(lockit clean_pool);

our (@EXPORT, @EXPORT_OK);
@EXPORT_OK
  = qw(create_webapi create_websocket_server create_worker kill_service unstable_worker job_create client_output);

sub kill_service {
    my $pid    = shift;
    my $forced = shift;
    kill TERM => $pid;
    kill KILL => $pid if $forced;
    waitpid($pid, 0);
}

sub create_webapi {
    my $mojoport = shift;

    $startingpid = $$;
    my $mojopid = fork();
    if ($mojopid == 0) {
        # TODO: start the server manually - and make it silent
        # Run openQA in test mode - it will mock Scheduler and Websockets DBus services
        $ENV{MOJO_MODE}   = 'test';
        $ENV{MOJO_LISTEN} = "127.0.0.1:$mojoport";
        Mojolicious::Commands->start_app('OpenQA::WebAPI', 'daemon', '-l', "http://127.0.0.1:$mojoport/");
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
            last if $socket;
            sleep 1 if time - $t < 1;
        }
    }
    return $mojopid;
}

sub create_websocket_server {
    my $port = shift;
    $wspid = fork();
    if ($wspid == 0) {
        $ENV{MOJO_LISTEN} = "http://127.0.0.1:$port";
        use OpenQA::WebSockets;
        OpenQA::WebSockets::run;
        Devel::Cover::report() if Devel::Cover->can('report');
        _exit(0);
    }
    else {
        # wait for websocket server
        my $wait = time + 20;
        while (time < $wait) {
            my $t      = time;
            my $socket = IO::Socket::INET->new(
                PeerHost => '127.0.0.1',
                PeerPort => $wsport,
                Proto    => 'tcp'
            );
            last if $socket;
            sleep 1 if time - $t < 1;
        }
    }
    return $wspid;
}

sub create_worker {
    my ($apikey, $apisecret, $host, $instance) = @_;
    my $connect_args = "--instance=${instance} --apikey=${apikey} --apisecret=${apisecret} --host=${host}";

    my $workerpid = fork();
    if ($workerpid == 0) {
        exec("perl ./script/worker $connect_args --isotovideo=../os-autoinst/isotovideo --verbose");
        die "FAILED TO START WORKER";
    }
    return $workerpid;
}

sub unstable_worker {
    # the help of the Doctor would be really appreciated here.
    my ($apikey, $apisecret, $host, $instance, $ticks) = @_;
    $ticks = 1 unless $ticks;

    my $pid = fork();
    if ($pid == 0) {
        use Mojo::Util 'monkey_patch';
        use Mojo::IOLoop;
        my ($worker_settings, $host_settings)
          = read_worker_config($instance, $host);    # It will read from config file, so watch out
        $OpenQA::Worker::Common::worker_settings = $worker_settings;
        $OpenQA::Worker::Common::instance        = $instance;


        # XXX: this should be sent to the scheduler to be included in the worker's table
        $ENV{QEMUPORT} = ($instance) * 10 + 20002;
        $ENV{VNC}      = ($instance) + 90;
        # Mangle worker main()
        monkey_patch 'OpenQA::Worker', main => sub {
            my ($host_settings) = @_;
            my $dir;
            for my $h (@{$host_settings->{HOSTS}}) {
                my @dirs = ($host_settings->{$h}{SHARE_DIRECTORY}, catdir($OpenQA::Utils::prjdir, 'share'));
                ($dir) = grep { $_ && -d } @dirs;
                unless ($dir) {
                    log_error("Can not find working directory for host $h. Ignoring host");
                    next;
                }

                Mojo::IOLoop->next_tick(
                    sub { OpenQA::Worker::Common::register_worker($h, $dir, $host_settings->{$h}{TESTPOOLSERVER}) });
            }
        };

        OpenQA::Worker::init($host_settings, {apikey => $apikey, apisecret => $apisecret});
        OpenQA::Worker::main($host_settings);
        for (0 .. $ticks) {
            Mojo::IOLoop->singleton->one_tick;
        }
        Devel::Cover::report() if Devel::Cover->can('report');
        do { 1 } while 1;
        _exit(0);
    }

    return $pid;

}

sub job_create {
    my $schema = shift;
    return unless $schema;
    my $job = $schema->resultset('Jobs')->create_from_settings(@_);
    # reload all values from database so we can check against default values
    $job->discard_changes;
    return $job;
}

sub read_worker_config {
    my ($instance, $host) = @_;
    my $worker_dir = $ENV{OPENQA_CONFIG} || '/etc/openqa';
    my $cfg = Config::IniFiles->new(-file => $worker_dir . '/workers.ini');

    my $sets = {};
    for my $section ('global', $instance) {
        if ($cfg && $cfg->SectionExists($section)) {
            for my $set ($cfg->Parameters($section)) {
                $sets->{uc $set} = $cfg->val($section, $set);
            }
        }
    }
    # use separate set as we may not want to advertise other host confiuration to the world in job settings
    my $host_settings;
    $host ||= $sets->{HOST} ||= 'localhost';
    delete $sets->{HOST};
    my @hosts = split / /, $host;
    for my $section (@hosts) {
        if ($cfg && $cfg->SectionExists($section)) {
            for my $set ($cfg->Parameters($section)) {
                $host_settings->{$section}{uc $set} = $cfg->val($section, $set);
            }
        }
        else {
            $host_settings->{$section} = {};
        }
    }
    $host_settings->{HOSTS} = \@hosts;

    return $sets, $host_settings;
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

1;
