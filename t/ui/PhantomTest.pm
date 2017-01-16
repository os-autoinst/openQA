package t::ui::PhantomTest;

use Mojo::IOLoop::Server;
# Start command line interface for application
require Mojolicious::Commands;
require OpenQA::Test::Database;

# specify the dependency here
use Test::Selenium::Chrome 1.02;
use Test::Selenium::PhantomJS;

our $_driver;
our $mojopid;
our $mojoport;
our $startingpid = 0;

=head2 start_app

  start_app([$schema_hook]);

Fork a server instance with database creation and return the server port.

By default the database is created based on the fixture set.

The optional parameter C<$schema_hook> allows to provide a custom way of creating a database, e.g.

    sub schema_hook {
        my $schema = OpenQA::Test::Database->new->create;
        # delete unused job id 1234
        $schema->resultset('Jobs')->find(1234)->delete;
    }
    start_app(\&schema_hook);
=cut


sub start_app {
    my ($schema_hook) = @_;
    $mojoport = Mojo::IOLoop::Server->generate_port;

    $startingpid = $$;
    $mojopid     = fork();
    if ($mojopid == 0) {
        if ($schema_hook) {
            $schema_hook->();
        }
        else {
            OpenQA::Test::Database->new->create;
        }
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
    return $mojoport;
}

sub start_phantomjs {
    my ($mojoport) = @_;

    # Connect to it
    eval {
        my %opts = (
            base_url          => "http://localhost:$mojoport/",
            inner_window_size => [600, 800],
            default_finder    => 'css',
            webelement_class  => 'Test::Selenium::Remote::WebElement'
        );
        if ($ENV{SELENIUM_CHROME}) {
            # chromedriver is unfortunately hidden on openSUSE
            my @chromiumdirs = qw(/usr/lib64/chromium);
            for my $dir (@chromiumdirs) {
                if (-d $dir) {
                    $ENV{PATH} = "$ENV{PATH}:$dir";
                }
            }
            $_driver = Test::Selenium::Chrome->new(%opts);
        }
        else {
            $opts{custom_args} = "--webdriver-logfile=t/log_phantomjs --webdriver-loglevel=DEBUG";
            $_driver = Test::Selenium::PhantomJS->new(%opts);
        }
        $_driver->set_implicit_wait_timeout(2000);
        $_driver->set_window_size(600, 800);
        $_driver->get('/');
    };
    die $@ if ($@);

    return $_driver;
}

sub make_screenshot($) {
    my ($fn) = (@_);

    open(my $fh, '>', $fn);
    binmode($fh);
    my $png_base64 = $_driver->screenshot();
    print($fh MIME::Base64::decode_base64($png_base64));
    close($fh);
}

sub call_phantom {
    my ($schema_hook) = @_;
    # fail if phantomjs or Selenium::Remote::Driver are unavailable
    use IPC::Cmd qw[can_run];
    use Module::Load::Conditional qw(can_load);
    if (!can_load(modules => {'Selenium::PhantomJS' => undef,})) {
        return undef;
    }

    my $mojoport = start_app($schema_hook);
    return start_phantomjs($mojoport);
}

sub wait_for_ajax {
    my ($check_interval) = (@_);
    if (!$check_interval) {
        $check_interval = 0.25;
    }
    while (!$_driver->execute_script("return jQuery.active == 0")) {
        sleep $check_interval;
    }
}

sub kill_phantom() {
    return unless $$ == $startingpid;
    if ($_driver) {
        $_driver->quit();
        $_driver->shutdown_binary;
        $_driver = undef;
    }
    if ($mojopid) {
        kill('TERM', $mojopid);
        waitpid($mojopid, 0);
        $mojopid = undef;
    }
}

sub get_mojoport {
    return $mojoport;
}

END {
    kill_phantom;
}

1;
