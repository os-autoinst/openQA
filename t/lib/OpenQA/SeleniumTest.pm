package OpenQA::SeleniumTest;
use base 'Exporter';

use Mojo::IOLoop::Server;
use strict;

# Start command line interface for application
require Mojolicious::Commands;
require OpenQA::Test::Database;

our @EXPORT = qw($drivermissing check_driver_modules start_driver
  call_driver kill_driver wait_for_ajax disable_bootstrap_animations
  open_new_tab mock_js_functions element_visible element_hidden
  javascript_console_has_no_warnings_or_errors);

use Data::Dump 'pp';
use Test::More;
use Try::Tiny;
use Time::HiRes 'time';

our $_driver;
our $mojopid;
our $mojoport;
our $startingpid   = 0;
our $drivermissing = 'Install Selenium::Remote::Driver and Selenium::Chrome to run these tests';

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
    $mojoport = $ENV{MOJO_PORT} // Mojo::IOLoop::Server->generate_port;

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

sub start_driver {
    my ($mojoport) = @_;

    # Connect to it
    eval {
        my %opts = (
            base_url           => "http://localhost:$mojoport/",
            default_finder     => 'css',
            webelement_class   => 'Test::Selenium::Remote::WebElement',
            extra_capabilities => {
                loggingPrefs  => {browser => 'ALL'},
                chromeOptions => {args    => []}
            },
        );

        # chromedriver is unfortunately hidden on openSUSE
        my @chromiumdirs = qw(/usr/lib64/chromium);
        for my $dir (@chromiumdirs) {
            if (-d $dir) {
                $ENV{PATH} = "$ENV{PATH}:$dir";
            }
        }
        $opts{custom_args} = "--log-path=t/log_chromedriver";
        unless ($ENV{NOT_HEADLESS}) {
            push(@{$opts{extra_capabilities}{chromeOptions}{args}}, ('--headless', '--disable-gpu'));
        }
        $_driver = Test::Selenium::Chrome->new(%opts);
        $_driver->set_implicit_wait_timeout(2000);
        $_driver->set_window_size(600, 800);
        $_driver->get("http://localhost:$mojoport/");

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

# opens a new tab/window for the specified URL and returns its handle
# remarks:
#  * does not switch to the new tab, use $driver->switch_to_window() for that
#  * see 33-developer_mode.t for an example
sub open_new_tab {
    my ($url) = @_;

    # open new window using JavaScript API (Selenium::Remote::Driver doesn't seem to provide a method)
    $url = $url ? "\"$url\"" : 'window.location';
    $_driver->execute_script("window.open($url);");

    # assume the last window handle is the one of the newly created window
    return $_driver->get_window_handles()->[-1];
}

sub check_driver_modules {

    # load required modules if possible. DO NOT EVER PUT THESE IN
    # 'use' FUNCTION CALLS! Always use can_load! Otherwise you will
    # break the case where they are not available and tests should
    # be skipped.
    use Module::Load::Conditional qw(can_load);
    return can_load(
        modules => {
            'Test::Selenium::Chrome'   => '1.20',
            'Selenium::Remote::Driver' => undef,
        });
}

sub call_driver {

    # return a omjs driver using specified schema hook if modules
    # are available, otherwise return undef
    return undef unless check_driver_modules;
    my ($schema_hook) = @_;
    my $mojoport = start_app($schema_hook);
    return start_driver($mojoport);
}

sub _default_check_interval {
    return shift // 0.25;
}

sub wait_for_ajax {
    my $check_interval = _default_check_interval(shift);
    while (!$_driver->execute_script("return jQuery.active == 0")) {
        sleep $check_interval;
    }
}

sub disable_bootstrap_animations {
    my @rules = (
        "'.fade', '-webkit-transition: none !important; transition: none !important;'",
        "'.collapsing', '-webkit-transition: none !important; transition: none !important;'",
    );
    for my $rule (@rules) {
        $_driver->execute_script("document.styleSheets[0].addRule($rule, 1);");
    }
}

sub javascript_console_has_no_warnings_or_errors {
    my ($test_name_suffix) = @_;
    $test_name_suffix //= '';

    my $log = $_driver->get_log('browser');
    my @errors;
    for my $log_entry (@$log) {
        my $level = $log_entry->{level};
        if ($level eq 'DEBUG' or $level eq 'INFO') {
            next;
        }

        my $source = $log_entry->{source};
        my $msg    = $log_entry->{message};
        if ($source eq 'network') {
            # ignore errors when gravatar not found
            next if ($msg =~ m,/gravatar/,);
            # FIXME: loading thumbs during live run causes 404. ignore for now
            next if ($msg =~ m,/thumb/, || $msg =~ m,/.thumbs/,);
        }
        elsif ($source eq 'javascript') {
            # FIXME: ignore WebSocket error for now (connection errors are tracked via devel console anyways)
            next if ($msg =~ m/ws\-proxy.*Close received/);
   # FIXME: find the reason why Chromium says we're trying to send something over an already closed WebSocket connection
            next if ($msg =~ m/Data frame received after close/);
        }
        push(@errors, $log_entry);
    }

    if (@errors) {
        diag('javascript console output: ' . pp(\@errors));
        ok(scalar @errors eq 0, 'no errors or warnings on javascript console' . $test_name_suffix);
    }
    return scalar @errors eq 0;    #TODO: fix this return value
}

# mocks the specified JavaScript functions (reverted when navigating to another page)
sub mock_js_functions {
    my (%functions_to_mock) = @_;

    my $java_script = '';
    $java_script .= "window.$_ = function(arg1, arg2) { $functions_to_mock{$_} };" for (keys %functions_to_mock);

    print("injecting JavaScript: $java_script\n");
    $_driver->execute_script($java_script);
}

# asserts that an element is visible and optionally whether it does (not) contain the expected phrases
sub element_visible {
    my ($selector, $like, $unlike) = @_;

    my @elements = $_driver->find_elements($selector);
    is(scalar @elements, 1, $selector . ' present exactly once');

    my $element = $elements[0];
    ok($element->is_displayed(), $selector . ' visible');

    # assert the element's text
    my $element_text = $element->get_text();
    if ($like) {
        if (ref $like eq 'ARRAY') {
            like($element_text, $_, "$selector contains $_") for (@$like);
        }
        else {
            like($element_text, $like, "$selector contains expected text");
        }
    }
    if ($unlike) {
        if (ref $unlike eq 'ARRAY') {
            unlike($element_text, $_, "$selector does not contain $_") for (@$unlike);
        }
        else {
            unlike($element_text, $unlike, "$selector does not contain text");
        }
    }
}

# asserts that an element is part of the page but hidden
sub element_hidden {
    my ($selector) = @_;

    my @elements = $_driver->find_elements($selector);
    is(scalar @elements, 1, $selector . ' present exactly once');
    ok(!$elements[0]->is_displayed(), $selector . ' hidden');
}

sub kill_driver() {
    return unless $startingpid && $$ == $startingpid;
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
    kill_driver;
}

1;
