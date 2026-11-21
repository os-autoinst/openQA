# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -base, -signatures;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Warnings ':report_warnings';
use Mojo::File qw(path);
use File::Temp qw(tempdir);
use OpenQA::Test::Screenshot qw(compare_png load_png);
use OpenQA::Test::TimeLimit '300';
use OpenQA::Test::VisualFixtures qw(init_visual_data login visual_pages);
use OpenQA::SeleniumTest;

my $tolerance = 0.01;
my $refs = path('t/data/screenshots');
my $shots = path($ENV{OPENQA_VISUAL_SHOTS} // tempdir, 'visual-baseline');
my $generate = $ENV{OPENQA_VISUAL_BASELINE};
note 'knobs: OPENQA_VISUAL_BASELINE=1 writes baselines, OPENQA_VISUAL_SHOTS keeps the captures';
$shots->make_path;
$refs->make_path if $generate;

my $fixed_time = '2020-01-01 00:01:00';
init_visual_data($fixed_time);

driver_missing unless my $driver = call_driver;
disable_timeout;
my $url = OpenQA::SeleniumTest::get_mojo_url;
login($driver, $url);

my ($major) = $driver->execute_script('return navigator.userAgent') =~ m{(?:Headless)?Chrome/(\d+)};
my $version_ref = $refs->child('chromium_version.txt');
if ($generate) { $version_ref->spew("$major\n") }    # uncoverable statement
else {
    is $version_ref->slurp, "$major\n", 'baselines were created with the same Chromium major as the capture browser'
      or diag 'baselines recorded for ' . $version_ref->slurp;
}

sub stabilise_page () {
    $driver->execute_script(<<'JS');
const style = document.createElement('style');
style.textContent = '*,::before,::after{animation:none!important;transition:none!important;caret-color:transparent!important}';
document.head.appendChild(style);
const fixed = new Date('2020-01-01 00:01:00');
window.Date = new Proxy(Date, {
  construct (target, args) { return args.length ? new target(...args) : new target(fixed); },
  apply (target, thisArg, args) { return args.length ? target(...args) : String(fixed); },
});
JS
}

sub pixel_compare ($name, $path) {
    $driver->get($url . $path);
    wait_for_ajax_and_animations;
    stabilise_page;
    my $shot = $shots->child("$name.png");
    $driver->capture_screenshot("$shot");
    my $ref = $refs->child("$name.png");
    if ($generate) {
        ok $shot->copy("$ref"), "$name: baseline written to $ref";    # uncoverable statement
        return undef;    # uncoverable statement
    }
    return ok 0, "$name: baseline $ref is missing, run with OPENQA_VISUAL_BASELINE=1"
      unless -e $ref;    # uncoverable statement
    my $diff = compare_png(load_png($ref->slurp), load_png($shot->slurp));
    ok $diff <= $tolerance, "$name: pixels match baseline, diff " . sprintf('%.3f', $diff) . '%';
}

for my $page (visual_pages) {
    my ($name, $path) = @$page;
    subtest $name => sub {
        pixel_compare($name, $path);
    };
}

kill_driver;
done_testing();
