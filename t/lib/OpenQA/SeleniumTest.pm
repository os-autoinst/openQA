package OpenQA::SeleniumTest;

use Test::Most;

use Mojo::Base -signatures;
use base 'Exporter';

require OpenQA::Test::Database;

our @EXPORT = qw(driver_missing check_driver_modules enable_timeout
  disable_timeout start_driver
  call_driver kill_driver wait_for_ajax disable_bootstrap_animations
  wait_for_ajax_and_animations
  open_new_tab mock_js_functions element_visible element_hidden
  element_not_present javascript_console_has_no_warnings_or_errors
  wait_until wait_until_element_gone wait_for_element
  element_prop element_prop_by_selector map_elements);

use Data::Dump 'pp';
use IPC::Run qw(start);
use Mojo::IOLoop::Server;
use Mojo::Server::Daemon;
use Try::Tiny;
use Time::HiRes qw(time sleep);
use OpenQA::WebAPI;
use OpenQA::Log 'log_info';
use OpenQA::Utils;
use OpenQA::Test::Utils;
use POSIX '_exit';

our $_driver;
our $webapi;
our $mojoport;
our $startingpid = 0;

sub _start_app {
    my ($args) = @_;
    $mojoport = $ENV{OPENQA_BASE_PORT} = $args->{mojoport} // $ENV{MOJO_PORT} // Mojo::IOLoop::Server->generate_port;
    $startingpid = $$;
    $webapi = OpenQA::Test::Utils::create_webapi($mojoport);
    return $mojoport;
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
            base_url => "http://localhost:$mojoport/",
            default_finder => 'css',
            webelement_class => 'Test::Selenium::Remote::WebElement',
            extra_capabilities => {
                loggingPrefs => {browser => 'ALL'},
                map { $_ => {args => []} } @chrome_option_keys,
            },
            error_handler => sub {
                # generate Test::Most failure instead of croaking to preserve
                # context but bail out to not have repeated entries for the
                # same problem exceeded console scrollback buffers easily
                my ($driver, $exception, $args) = @_;    # uncoverable statement
                my $err = (split /\n/, $exception)[0] =~ s/Error while executing command: //r;   # uncoverable statement
                $err .= ' at ' . __FILE__ . ':' . __LINE__;    # uncoverable statement

                # prevent aborting the complete test when interactively debugging
                $INC{'perl5db.pl'} ? fail $err : BAIL_OUT($err);    # uncoverable statement
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
        my $startup_timeout = $ENV{OPENQA_SELENIUM_TEST_STARTUP_TIMEOUT} // 10;
        $_driver = Test::Selenium::Chrome->new(%opts, startup_timeout => $startup_timeout);
        $_driver->{is_wd3} = 0;    # ensure the Selenium::Remote::Driver instance uses JSON Wire protocol
        enable_timeout;
        # Scripts are considered stuck after this timeout
        $_driver->set_timeout(script => $ENV{OPENQA_SELENIUM_SCRIPT_TIMEOUT_MS} // 2000);
        $_driver->set_window_size(600, 800);
        $_driver->get("http://localhost:$mojoport/");

    };
    die $@ if ($@);

    return $_driver;
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
            'Test::Selenium::Chrome' => '1.20',
            'Selenium::Remote::Driver' => undef,
        });
}

sub call_driver {
    # return a omjs driver if modules are available, otherwise return undef
    return undef unless check_driver_modules;
    my ($args) = @_;
    my $mojoport = _start_app($args);
    return start_driver($mojoport);
}

sub _default_check_interval {
    return shift // 0.25;
}

sub wait_for_ajax {
    my (%args) = @_;
    my $check_interval = _default_check_interval($args{interval});
    my $timeout = 60 * 5;
    my $slept = 0;
    my $msg = $args{msg} ? (': ' . $args{msg}) : '';

    while (!$_driver->execute_script('return window.jQuery && jQuery.active === 0')) {
        if ($timeout <= 0) {
            fail("Wait for jQuery timed out$msg");    # uncoverable statement
            return undef;    # uncoverable statement
        }

        $args{with_minion}->perform_jobs_in_foreground if $args{with_minion};

        $timeout -= $check_interval;
        sleep $check_interval;
        $slept = 1;
    }
    pass("Wait for jQuery successful$msg");
    return $slept;
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
    my (%args) = @_;
    disable_bootstrap_animations();
    wait_for_ajax(%args);
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
        my $msg = $log_entry->{message};
        if ($source eq 'network') {
            # ignore errors when gravatar not found
            next if ($msg =~ qr/gravatar/);    # uncoverable statement

            # ignore that needle editor in 33-developer_mode.t is not instantly available
            next if ($msg =~ qr/tests\/1\/edit.*404/);    # uncoverable statement

            # FIXME: loading thumbs during live run causes 404. ignore for now
            # (',' is a quotation mark here and '/' part of expression to match)
            next if ($msg =~ qr,/thumb/, || $msg =~ qr,/.thumbs/,);    # uncoverable statement

            # ignore error responses in 13-admin.t testing YAML errors
            next if ($msg =~ qr/api\/v1\/exp.*\/job_templates_scheduling\/1003 - Failed.*/);    # uncoverable statement
        }
        elsif ($source eq 'javascript') {
            # ignore when the proxied ws connection is closed; connection errors are tracked via the devel console
            # anyways and when the test execution is over this kind of error is expected
            next if ($msg =~ qr/ws\-proxy.*Close received/);

            # ignore "connection establishment" ws errors in ws_console.js; the ws server might just not be running yet
            # and ws_console.js will retry
            next if ($msg =~ qr/ws_console.*Error in connection establishment/);    # uncoverable statement

            # FIXME: find the reason why Chromium says we are trying to send something over an already closed
            # WebSocket connection
            next if ($msg =~ qr/Data frame received after close/);    # uncoverable statement
        }
        push(@errors, $log_entry);
    }

    if (@errors) {
        diag('javascript console output' . $test_name_suffix . ': ' . pp(\@errors));
    }
    return scalar @errors eq 0;
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
    ok($element, $selector . ' exists') or return;
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

# returns an element's property
# note: Workaround for not relying on the functions Selenium::Remote::WebElement::get_value() and is_selected()
#       because they ceased to work in some cases with chromedriver 91.0.4472.77. (Whether the functions work or
#       not likely depends on how the property is populated.)
sub element_prop ($element_id, $property = 'value') {
    return $_driver->execute_script("return document.getElementById('$element_id').$property;");
}
sub element_prop_by_selector ($element_selector, $property = 'value') {
    return $_driver->execute_script("return document.querySelector('$element_selector').$property;");
}
sub map_elements ($selector, $mapping) {
    return $_driver->execute_script("return Array.from(document.querySelectorAll('$selector')).map(e => [$mapping]);");
}

sub wait_until {
    my ($check_function, $check_description, $timeout, $check_interval) = @_;
    $timeout //= 100;
    $check_interval //= .1;

    while (1) {
        if ($check_function->()) {
            pass($check_description);
            return 1;
        }
        if ($timeout <= 0) {
            fail($check_description);    # uncoverable statement
            return 0;    # uncoverable statement
        }
        $timeout -= $check_interval;
        wait_for_ajax(msg => $check_description) or sleep $check_interval;
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
    my (%args) = @_;
    my $selector = $args{selector};
    my $expected_is_displayed = $args{is_displayed};

    my $element;
    wait_until(
        sub {
            my @elements = $_driver->find_elements($selector);
            if (scalar @elements >= 1
                && (!defined $expected_is_displayed || $elements[0]->is_displayed == $expected_is_displayed))
            {
                $element = $elements[0];
            }
            return defined $element;
        },
        $args{description} // ($selector . ' present'),
        $args{timeout},
        $args{check_interval},
    );
    return $element;
}

sub kill_driver {
    return unless $startingpid && $$ == $startingpid;
    if ($_driver) {
        $_driver->quit();
        $_driver->shutdown_binary;
        $_driver = undef;
    }
    if ($webapi) {
        $webapi->signal('TERM');
        $webapi->finish;
    }
}

sub get_mojoport {
    return $mojoport;
}

sub driver_missing {
    diag 'Install Selenium::Remote::Driver and Selenium::Chrome to run these tests';
    done_testing;
    exit;
}

END {
    kill_driver;
}

1;
