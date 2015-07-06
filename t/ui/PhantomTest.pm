package t::ui::PhantomTest;

use Mojo::IOLoop::Server;
# Start command line interface for application
require Mojolicious::Commands;

our $_driver;
our $mojopid;
our $phantompid;

sub start_app {
    my $mojoport = Mojo::IOLoop::Server->generate_port;

    $mojopid = fork();
    if ($mojopid == 0) {
        OpenQA::Test::Database->new->create;
        # TODO: start the server manually - and make it silent
        Mojolicious::Commands->start_app('OpenQA::WebAPI', 'daemon', '-l', "http://127.0.0.1:$mojoport/");
        exit(0);
    }
    else {
        #$SIG{__DIE__} = sub { kill('TERM', $mojopid); };
        my $wait = time + 5;
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
    return $mojoport;
}

sub start_phantomjs {
    my ($mojoport) = @_;

    my $phantomport = Mojo::IOLoop::Server->generate_port;

    $phantompid = fork();
    if ($phantompid == 0) {
        exec('phantomjs', "--webdriver=127.0.0.1:$phantomport", "--debug=false");
        die "phantomjs didn't start\n";
    }
    else {
        # borrowed GPL code from WWW::Mechanize::PhantomJS
        #$SIG{__DIE__} = sub { kill('TERM', $phantompid); };
        my $wait = time + 20;
        while (time < $wait) {
            my $t      = time;
            my $socket = IO::Socket::INET->new(
                PeerHost => '127.0.0.1',
                PeerPort => $phantomport,
                Proto    => 'tcp',
            );
            sleep 1 if time - $t < 2;
            last if $socket;
        }
    }
    use Selenium::Remote::Driver;
    my $driver;
    # Connect to it
    eval {
        $driver = Selenium::Remote::Driver->new('port' => $phantomport);
        $driver->set_implicit_wait_timeout(5);
        $driver->set_window_size(600, 800);
        $driver->get("http://localhost:$mojoport/");
    };

    # if PhantomJS started, but so slow or unresponsive that SRD cannot connect to it,
    # kill it manually to avoid waiting for it indefinitely
    if ($@) {
        kill 'TERM', $mojopid;
        kill 'KILL', $phantompid;
        $mojopid = $phantompid = undef;
        die $@;
    }

    return $driver;
}

sub make_screenshot($) {
    my ($fn) = (@_);

    open(my $fh, '>', $fn);
    binmode($fh);
    my $png_base64 = $_driver->screenshot();
    print($fh MIME::Base64::decode_base64($png_base64));
    close($fh);
}

sub call_phantom() {
    use IPC::Cmd qw[can_run];
    if (!can_run('phantomjs')) {
        return undef;
    }

    my $mojoport = start_app;
    return $_driver = start_phantomjs($mojoport);
}

sub kill_phantom() {
    $_driver->quit();
    kill('TERM', $mojopid);
    waitpid($mojopid, 0);
    kill('TERM', $phantompid);
    waitpid($phantompid, 0);
}

1;
