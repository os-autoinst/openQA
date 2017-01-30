package t::ui::PhantomTest;
use base 'Exporter';

use Mojo::IOLoop::Server;
# Start command line interface for application
require Mojolicious::Commands;
require OpenQA::Test::Database;

@EXPORT = qw($phantommissing check_phantom_modules call_phantom kill_phantom wait_for_ajax javascript_console_is_empty);

use Data::Dump 'pp';
use Test::More;

our $_driver;
our $mojopid;
our $mojoport;
our $startingpid = 0;
our $phantommissing
  = 'Install Selenium::Remote::Driver and Selenium::PhantomJS (or Selenium::Chrome with SELENIUM_CHROME set) to run these tests';

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

sub check_phantom_modules {
    # load required modules if possible. DO NOT EVER PUT THESE IN
    # 'use' FUNCTION CALLS! Always use can_load! Otherwise you will
    # break the case where they are not available and tests should
    # be skipped.
    use Module::Load::Conditional qw(can_load);
    my $modname = $ENV{SELENIUM_CHROME} ? 'Test::Selenium::Chrome' : 'Test::Selenium::PhantomJS';
    my $modver = $ENV{SELENIUM_CHROME} ? '1.02' : undef;
    return can_load(modules => {$modname => $modver, 'Selenium::Remote::Driver' => undef,});
}

sub call_phantom {
    # return a phantomjs driver using specified schema hook if modules
    # are available, otherwise return undef
    return undef unless check_phantom_modules;
    my ($schema_hook) = @_;
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

sub javascript_console_is_empty {
    is(pp($_driver->get_log('browser')), "[]", "no errors on javascript console");
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
