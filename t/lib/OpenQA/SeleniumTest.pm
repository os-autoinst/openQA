package OpenQA::SeleniumTest;

use strict;
use warnings;

use base 'Exporter';

require OpenQA::Test::Database;

our @EXPORT = qw($drivermissing check_driver_modules enable_timeout
  disable_timeout start_driver
  call_driver kill_driver wait_for_ajax disable_bootstrap_animations
  wait_for_ajax_and_animations
  open_new_tab mock_js_functions element_visible element_hidden
  element_not_present javascript_console_has_no_warnings_or_errors
  wait_until wait_until_element_gone wait_for_element);

use Data::Dump 'pp';
use Mojo::IOLoop::Server;
use Mojo::Server::Daemon;
use Test::More;
use Try::Tiny;
use Time::HiRes 'time';
use OpenQA::WebAPI;
use OpenQA::Utils;
use OpenQA::Test::Utils;
use POSIX '_exit';

our $_driver;
our $mojopid;
our $gru_pid;
our $mojoport;
our $startingpid   = 0;
our $drivermissing = 'Install Selenium::Remote::Driver and Selenium::Chrome to run these tests';

sub _start_app {
    my ($schema_hook, $args) = @_;
    $schema_hook = sub { OpenQA::Test::Database->new->create }
      unless $schema_hook;
    $mojoport = $args->{mojoport} // $ENV{MOJO_PORT} // Mojo::IOLoop::Server->generate_port;

    $startingpid = $$;
    $mojopid     = OpenQA::Test::Utils::create_webapi($mojoport, $schema_hook);

    _start_gru() if ($args->{with_gru});
    return $mojoport;
}

sub _start_gru {
    $gru_pid = fork();
    if ($gru_pid == 0) {
        log_info("starting gru\n");
        $ENV{MOJO_MODE} = 'test';
        my $app = Mojo::Server->new->build_app('OpenQA::WebAPI');
        $app->minion->on(
            worker => sub {
                my ($minion, $worker) = @_;
                $worker->on(
                    dequeue => sub {
                        my ($worker, $job) = @_;
                        $job->on(cleanup => sub { Devel::Cover::report() if Devel::Cover->can('report') });
                    });
            });
        $app->start('gru', 'run', '-m', 'test');
        _exit(0);
    }
    return $gru_pid;
}

sub enable_timeout {
    $_driver->set_implicit_wait_timeout(2000);
}

sub disable_timeout {
    $_driver->set_implicit_wait_timeout(0);
}

sub start_driver {
    my ($mojoport) = @_;

    # Connect to it
    eval {
        # enforce the JSON Wire protocol (instead of using W3C WebDriver protocol)
        # note: This is required with Selenium::Remote::Driver 1.36 which would now use W3C mode leading
        #       to errors like "unknown command: unknown command: Cannot call non W3C standard command while
        #       in W3C mode".
        $Selenium::Remote::Driver::FORCE_WD2 = 1;

        # pass options for Chromium via chromeOptions *and* goog:chromeOptions to support all versions of
        # Selenium::Remote::Driver which switched to use goog:chromeOptions in version 1.36
        my @chrome_option_keys = (qw(chromeOptions goog:chromeOptions));

        my %opts = (
            base_url           => "http://localhost:$mojoport/",
            default_finder     => 'css',
            webelement_class   => 'Test::Selenium::Remote::WebElement',
            extra_capabilities => {
                loggingPrefs => {browser => 'ALL'},
                map { $_ => {args => []} } @chrome_option_keys,
            },
            error_handler => sub {
                # generate Test::More failure instead of croaking to preserve context
                my ($driver, $exception, $args) = @_;
                fail((split /\n/, $exception)[0] =~ s/Error while executing command: //r);
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
            push(@{$opts{extra_capabilities}{$_}{args}}, qw(--headless --disable-gpu --no-sandbox))
              for @chrome_option_keys;
        }
        $_driver = Test::Selenium::Chrome->new(%opts);
        $_driver->{is_wd3} = 0;    # ensure the Selenium::Remote::Driver instance uses JSON Wire protocol
        enable_timeout;
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
    my ($schema_hook, $args) = @_;
    my $mojoport = _start_app($schema_hook, $args);
    return start_driver($mojoport);
}

sub _default_check_interval {
    return shift // 0.25;
}

sub wait_for_ajax {
    my $check_interval = _default_check_interval(shift);
    my $timeout        = 60 * 5;

    while (!$_driver->execute_script('return window.jQuery && jQuery.active === 0')) {
        if ($timeout <= 0) {
            fail("Wait for jQuery timed out");
            return undef;
        }

        $timeout -= $check_interval;
        sleep $check_interval;
    }
    pass("Wait for jQuery successful");
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

sub wait_for_ajax_and_animations {
    disable_bootstrap_animations();
    wait_for_ajax();
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
            next if ($msg =~ qr/gravatar/);
            # ignore that needle editor in 33-developer_mode.t is not instantly available
            next if ($msg =~ qr/tests\/1\/edit.*404/);
            # FIXME: loading thumbs during live run causes 404. ignore for now
            # (',' is a quotation mark here and '/' part of expression to match)
            next if ($msg =~ qr,/thumb/, || $msg =~ qr,/.thumbs/,);
            # ignore error responses in 13-admin.t testing YAML errors
            next if ($msg =~ qr/api\/v1\/experimental\/job_templates_scheduling\/1003 - Failed to load resource/);
        }
        elsif ($source eq 'javascript') {
            # FIXME: ignore WebSocket error for now (connection errors are tracked via devel console anyways)
            next if ($msg =~ qr/ws\-proxy.*Close received/);
   # FIXME: find the reason why Chromium says we're trying to send something over an already closed WebSocket connection
            next if ($msg =~ qr/Data frame received after close/);
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
    ok($element,                 $selector . ' exists') or return;
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

# asserts that an element is not part of the page
sub element_not_present {
    my ($selector) = @_;

    my @elements = $_driver->find_elements($selector);
    is(scalar @elements, 0, $selector . ' not present');
}

sub wait_until {
    my ($check_function, $check_description, $timeout, $check_interval) = @_;
    $timeout        //= 10;
    $check_interval //= 1;

    while (1) {
        if ($check_function->()) {
            pass($check_description);
            return 1;
        }
        if ($timeout <= 0) {
            fail($check_description);
            return 0;
        }
        $timeout -= $check_interval;
        sleep $check_interval;
    }
}

sub wait_until_element_gone {
    my ($selector) = shift;

    wait_until(
        sub {
            return scalar(@{$_driver->find_elements($selector)}) == 0;
        },
        $selector . ' gone',
        @_,
    );
}

sub wait_for_element {
    my (%args)                = @_;
    my $selector              = $args{selector};
    my $expected_is_displayed = $args{is_displayed};

    my $element;
    wait_until(
        sub {
            my @elements = $_driver->find_elements($selector);
            if (scalar @elements >= 1
                && (!defined $expected_is_displayed || $elements[0]->is_displayed == $expected_is_displayed))
            {
                $element = $elements[0];
                return 1;
            }
            return 0;
        },
        $args{description} // ($selector . ' present'),
        $args{timeout},
        $args{check_interval},
    );
    return $element;
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
    if ($gru_pid) {
        kill('TERM', $gru_pid);
        waitpid($gru_pid, 0);
        $gru_pid = undef;
    }
}

sub get_mojoport {
    return $mojoport;
}

END {
    kill_driver;
}

1;
