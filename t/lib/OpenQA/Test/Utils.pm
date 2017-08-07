package OpenQA::Test::Utils;
use base 'Exporter';
use IO::Socket::INET;
use Mojolicious;
use POSIX '_exit';

our (@EXPORT, @EXPORT_OK);
@EXPORT_OK = qw(create_webapi create_websocket_server create_worker kill_service);

sub kill_service {
    my $pid = shift;
    kill TERM => $pid;
    waitpid($pid, 0);
}

sub create_webapi {
    my $mojoport = shift;

    $startingpid = $$;
    $mojopid     = fork();
    if ($mojopid == 0) {
        # TODO: start the server manually - and make it silent
        # Run openQA in test mode - it will mock Scheduler and Websockets DBus services
        $ENV{MOJO_MODE}   = 'test';
        $ENV{MOJO_LISTEN} = "127.0.0.1:$mojoport";
        Mojolicious::Commands->start_app('OpenQA::WebAPI', 'daemon', '-l', "http://127.0.0.1:$mojoport/");
        exit(0);
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
    sleep 60;

    return $workerpid;
}


1;
