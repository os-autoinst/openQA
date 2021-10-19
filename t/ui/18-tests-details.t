#!/usr/bin/env perl

# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use DateTime;
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings qw(:all :report_warnings);
use Mojo::JSON qw(decode_json encode_json);
use Mojo::File qw(path);
use Mojo::IOLoop;
use OpenQA::Test::TimeLimit '40';
use OpenQA::Test::Case;
use OpenQA::Test::Utils qw(prepare_clean_needles_dir prepare_default_needle);
use OpenQA::Client;
use OpenQA::Jobs::Constants;
use OpenQA::SeleniumTest;
use Module::Load::Conditional qw(can_load);

my $test_case = OpenQA::Test::Case->new;
my $schema_name = OpenQA::Test::Database->generate_schema_name;
my $schema = $test_case->init_data(
    schema_name => $schema_name,
    fixtures_glob =>
      '01-jobs.pl 02-workers.pl 03-users.pl 04-products.pl ui-18-tests-details/01-job_modules.pl 07-needles.pl'
);
my $jobs = $schema->resultset('Jobs');

# prepare needles dir
my $needle_dir_fixture = $schema->resultset('NeedleDirs')->find(1);
my $needle_dir = prepare_clean_needles_dir;
prepare_default_needle($needle_dir);

sub prepare_database {
    # set assigned_worker_id to test whether worker still displayed when job set to done
    # manually for Selenium test
    $jobs->find(99963)->update({assigned_worker_id => 1});

    # for the "investigation details test"
    my $ret = $jobs->find(99947)->duplicate;
    $jobs->find($ret->{99947}->{clone})->done(result => FAILED);

    # add a scheduled product
    my $scheduled_products = $schema->resultset('ScheduledProducts');
    my $scheduled_product_id = $scheduled_products->create(
        {
            distri => 'distri',
            flavor => 'dvd',
            build => '1234',
            settings => '{}'
        })->id;
    $jobs->find(99937)->update({scheduled_product_id => $scheduled_product_id});

    # store the needle dir's realpath within the database; that is what the lookup for the candidates menu is
    # expected to use
    $needle_dir_fixture->update({path => $needle_dir->realpath});

    my $assets = $schema->resultset('Assets');
    $assets->find({type => 'iso', name => 'openSUSE-13.1-DVD-i586-Build0091-Media.iso'})->update({size => 0});
}

prepare_database;

driver_missing unless my $driver = call_driver;
my $baseurl = $driver->get_current_url;
sub current_tab { $driver->find_element('.nav.nav-tabs .active')->get_text }

# returns the contents of the candidates combo box as hash (key: tag, value: array of needle names)
sub find_candidate_needles {
    # ensure the candidates menu is visible
    my @candidates_menus = $driver->find_elements('#candidatesMenu');
    is(scalar @candidates_menus, 1, 'exactly one candidates menu present at a time');
    # save implicit waiting time as long as we are only looking for elements
    # that should be visible already
    disable_timeout;
    $candidates_menus[0]->click();

    # read the tags/needles from the HTML structure
    my @section_elements = $driver->find_elements('#needlediff_selector ul table');
    my %needles_by_tag = map {
        # find tag name
        my @tag_elements = $driver->find_child_elements($_, 'thead > tr');
        is(scalar @tag_elements, 1, 'exactly one tag header present' . "\n");

        # find needle names
        my @needles;
        my @needle_elements = $driver->find_child_elements($_, 'tbody > tr');
        for my $needle_element (@needle_elements) {
            my @needle_parts = $driver->find_child_elements($needle_element, 'td');
            next unless @needle_parts;

            is(scalar @needle_parts, 3, 'exactly three parts per needle present (percentage, name, diff buttons)');
            push(@needles,
                    OpenQA::Test::Case::trim_whitespace($needle_parts[0]->get_text()) . '%: '
                  . OpenQA::Test::Case::trim_whitespace($needle_parts[1]->get_text()));
        }

        OpenQA::Test::Case::trim_whitespace($tag_elements[0]->get_text()) => \@needles;
    } @section_elements;

    # further assertions
    my $selected_needle_count = scalar @{$driver->find_elements('#needlediff_selector tr.selected')};
    ok($selected_needle_count <= 1, "at most one needle is selected at a time ($selected_needle_count selected)");

    # close the candidates menu again, return results
    $driver->find_element('#candidatesMenu')->click();
    enable_timeout;
    return \%needles_by_tag;
}

$driver->find_element_by_link_text('Login')->click();
is($driver->find_element('#user-action a')->get_text(), 'Logged in as Demo', 'logged in as demo');

$driver->get('/tests/99937');
disable_bootstrap_animations;

subtest 'tab navigation via history' => sub {
    is(current_tab, 'Details', 'starting on Details tab for completed job');
    $driver->find_element_by_link_text('Settings')->click();
    is(current_tab, 'Settings', 'switched to settings tab');
    $driver->go_back();
    is(current_tab, 'Details', 'back to details tab');
};

subtest 'show job modules execution time' => sub {
    my $tds = $driver->find_elements('.component');
    my %modules_execution_time = (
        aplay => '2m 26s',
        consoletest_finish => '2m 44s',
        gnucash => '3m 7s',
        installer_timezone => '34s'
    );
    for my $td (@$tds) {
        my $module_name = $td->children('div')->[0]->get_text();
        is(
            $td->children('span')->[0]->get_text(),
            $modules_execution_time{$module_name},
            $module_name . ' execution time showed correctly'
        ) if $modules_execution_time{$module_name};
    }
};

subtest 'displaying image result with candidates' => sub {
    $driver->find_element('[href="#step/bootloader/1"]')->click();
    wait_for_ajax;
    is_deeply(find_candidate_needles, {'inst-bootmenu' => []}, 'correct tags displayed');
};

subtest 'filtering' => sub {
    # load Selenium::Remote::WDKeys module or skip this test if not available
    return plan skip_all => 'Install Selenium::Remote::WDKeys to run this test'
      unless can_load(modules => {'Selenium::Remote::WDKeys' => undef,});

    # define test helper
    my $count_steps = sub {
        my ($result) = @_;
        return $driver->execute_script("return \$('#results .result${result}:visible').length;");
    };
    my $count_headings = sub {
        return $driver->execute_script("return \$('#results td[colspan=\"3\"]:visible').length;");
    };

    # check initial state (no filters enabled)
    ok(!$driver->find_element('#details-name-filter')->is_displayed(), 'name filter initially not displayed');
    ok(!$driver->find_element('#details-only-failed-filter')->is_displayed(), 'failed filter initially not displayed');
    is($count_steps->('ok'), 5, 'number of passed steps without filter');
    is($count_steps->('failed'), 2, 'number of failed steps without filter');
    is($count_headings->(), 3, 'number of module headings without filter');

    # show filter form
    $driver->find_element('.details-filter-toggle a')->click();

    # enable name filter
    $driver->find_element('#details-name-filter')->send_keys('er');
    is($count_steps->('ok'), 2, 'number of passed steps only with name filter');
    is($count_steps->('failed'), 1, 'number of failed steps only with name filter');
    is($count_headings->(), 0, 'no module headings shown when filter active');

    # enable failed filter
    $driver->find_element('#details-only-failed-filter')->click();
    is($count_steps->('ok'), 0, 'number of passed steps with both filters');
    is($count_steps->('failed'), 1, 'number of failed steps with both filters');
    is($count_headings->(), 0, 'no module headings shown when filter active');

    # disable name filter
    $driver->find_element('#details-name-filter')->send_keys(
        Selenium::Remote::WDKeys->KEYS->{end},
        Selenium::Remote::WDKeys->KEYS->{backspace},
        Selenium::Remote::WDKeys->KEYS->{backspace},
    );
    is($count_steps->('ok'), 0, 'number of passed steps only with failed filter');
    is($count_steps->('failed'), 2, 'number of failed steps only with failed filter');
    is($count_headings->(), 0, 'no module headings shown when filter active');

    # disable failed filter
    $driver->find_element('#details-only-failed-filter')->click();
    is($count_steps->('ok'), 5, 'same number of passed steps as initial');
    is($count_steps->('failed'), 2, 'same number of failed steps as initial');
    is($count_headings->(), 3, 'module headings shown again');
};

sub check_report_links {
    my ($failed_module, $failed_step, $container) = @_;

    my @report_links
      = $container
      ? $driver->find_child_elements($container, '.report')
      : $driver->find_elements('#preview_container_in .report');
    my @title = map { $_->get_attribute('title') } @report_links;
    is($title[0], 'Report product bug', 'product bug report URL available');
    is($title[1], 'Report test issue', 'test issue report URL available');
    my @url = map { $_->get_attribute('href') } @report_links;
    like($url[0], qr{bugzilla.*enter_bug.*tests%2F99937}, 'bugzilla link referencing current test');
    like($url[0], qr{in\+scenario\+opensuse-13\.1-DVD-i586-kde}, 'bugzilla link contains scenario');
    like($url[1], qr{progress.*new}, 'progress/redmine link for reporting test issues');
    like($url[1], qr{in\+scenario\+opensuse-13\.1-DVD-i586-kde}, 'progress/redmine link contains scenario');
    like(
        $url[1],
        qr{in.*$failed_module.*$failed_module%2Fsteps%2F$failed_step},
        'progress/redmine link refers to right module/step'
    );
}

subtest 'bug reporting' => sub {
    subtest 'screenshot' => sub {
        # note: image of bootloader step from previous test 'correct tags displayed' is still shown
        check_report_links(bootloader => 1);
        # close bootloader step preview so it will not hide other elements used by subsequent tests
        $driver->find_element('.links_a.current_preview')->click;
    };
};

subtest 'scheduled product shown' => sub {
    # still on test 99937
    my $scheduled_product_link = $driver->find_element('#scheduled-product-info a');
    my $expected_scheduled_product_id = $schema->resultset('Jobs')->find(99937)->scheduled_product_id;
    is($scheduled_product_link->get_text(), 'distri-dvd-1234', 'scheduled product name');
    like(
        $scheduled_product_link->get_attribute('href'),
        qr/\/admin\/productlog\?id=$expected_scheduled_product_id/,
        'scheduled product href'
    );
    $driver->get('/tests/99963');
    like(
        $driver->find_element_by_id('scheduled-product-info')->get_text(),
        qr/job has not been created by posting an ISO.*but possibly the original job/,
        'scheduled product not present, clone'
    );
    $driver->get('/tests/99926');
    like(
        $driver->find_element_by_id('scheduled-product-info')->get_text(),
        qr/job has not been created by posting an ISO/,
        'scheduled product not present, no clone'
    );
};

subtest 'reason and log details on incomplete jobs' => sub {
    # still on test 99926
    is(current_tab, 'Details', 'starting on Details tab also for incomplete jobs');
    like($driver->find_element('#info_box')->get_text(), qr/Reason: just a test/, 'reason shown');
    wait_for_ajax(msg => 'test details tab for job 99926 loaded');
    my $log_element = $driver->find_element_by_xpath('//*[@id="details"]//pre[string-length(text()) > 0]');
    like($log_element->get_attribute('data-src'), qr/autoinst-log.txt/, 'log file embedded');
    like($log_element->get_text(), qr/Crashed\?/, 'log contents loaded');
};

subtest 'running job' => sub {
    # assume there's a running job module
    my $job_modules = $schema->resultset('JobModules');
    $job_modules->search({job_id => 99963, name => 'glibc_i686'})->update({result => RUNNING});

    # assume the running job has no job modules so far (by temporarily assigning it to some other job which has
    # no modules)
    my $job_module_count = $job_modules->search({job_id => 99963})->update({job_id => 99961});

    $driver->get('/tests/99963');
    like(current_tab, qr/live/i, 'live tab active by default');

    subtest 'info panel contents' => sub {
        like(
            $driver->find_element('#assigned-worker')->get_text,
            qr/[ \n]*Assigned worker:[ \n]*localhost:1[ \n]*/,
            'worker displayed when job running'
        );
        like($driver->find_element('#assigned-worker a')->get_attribute('href'),
            qr{.*/admin/workers/1$}, 'link to worker correct');
        like(
            $driver->find_element('#scenario-description')->get_text,
            qr/[ \n]*Simple kde test, before advanced_kde[ \n]*/,
            'scenario description is displayed'
        );
    };
    subtest 'details tab with empty test module table' => sub {
        $driver->find_element_by_link_text('Details')->click;
        wait_for_ajax(msg => 'details tab rendered');
        my $test_modules_table = $driver->find_element_by_id('results');
        isnt($test_modules_table, undef, 'results table shown') or return undef;
        is(scalar @{$driver->find_child_elements($test_modules_table, 'tbody tr')}, 0, 'no results shown so far');
    };
    subtest 'test module table is populated (without reload) when test modules become available' => sub {
        $job_modules->search({job_id => 99961})->update({job_id => 99963});
        $driver->execute_script('updateStatus()');    # avoid wasting time by triggering the status update immediately
        wait_for_ajax(msg => 'wait for test modules being loaded');

        is($driver->find_element('#module_glibc_i686 .result')->get_text, RUNNING, 'glibc_i686 is running');
        is(scalar @{$driver->find_elements('#results .result')},
            $job_module_count, "all $job_module_count job modules rendered");
    };
};

subtest 'render bugref links in thumbnail text windows' => sub {
    $driver->get('/tests/99946');
    wait_for_ajax(msg => 'details tab for job 99946 loaded (2)');
    $driver->find_element('[title="Soft Failed"]')->click();
    wait_for_ajax(msg => 'preview container for softfailed step loaded');
    is(
        $driver->find_element_by_id('preview_container_in')->get_text(),
        'Test bugref bsc#1234 https://fate.suse.com/321208',
        'bugref text correct'
    );
    my @a = $driver->find_elements('#preview_container_in pre a', 'css');
    is((shift @a)->get_attribute('href'), 'https://bugzilla.suse.com/show_bug.cgi?id=1234', 'bugref href correct');
    is((shift @a)->get_attribute('href'), 'https://fate.suse.com/321208', 'regular href correct');
};

subtest 'render text results' => sub {
    # still on 99946

    # select a text result
    $driver->find_element('[title="Some text result from external parser"]')->click();
    like($driver->get_current_url(), qr/#step\/logpackages\/6/, 'url contains step');
    is(
        $driver->find_element('.current_preview .resborder')->get_text(),
        'This is a dummy result to test rendering text results from external parsers.',
        'text result rendered correctly'
    );

    # select another text result
    $driver->find_element('[title="Another text result from external parser"]')->click();
    like($driver->get_current_url(), qr/#step\/logpackages\/7/, 'url contains step');
    my @lines = split(/\n/, $driver->find_element('.current_preview .resborder')->get_text());
    is(scalar @lines, 11, 'correct number of lines');

    # unselecting text result
    $driver->find_element('[title="Another text result from external parser"]')->click();
    unlike($driver->get_current_url(), qr/#step/, 'step removed from url');

    # check whether other text results (not parser output) are unaffected
    $driver->find_element('[title="One more text result"]')->click();
    wait_for_ajax(msg => 'preview container for text result step loaded');
    is(
        $driver->find_element_by_id('preview_container_in')->get_text(),
        "But this one doesn't come from parser so\nit should not be displayed in a special way.",
        'text results not from parser shown in ordinary preview container'
    );
    # note: check whether the softfailure is unaffected is already done in subtest 'render bugref links in thumbnail
    # text windows'

    subtest 'external table' => sub {
        element_not_present('#external-table');
        $driver->find_element_by_link_text('External results')->click();
        wait_for_ajax(msg => 'external results tab for job 99946 loaded');
        my $external_table = $driver->find_element_by_id('external-table');
        is($external_table->is_displayed(), 1, 'external table visible after clicking its tab header');
        my @rows = $driver->find_child_elements($external_table, 'tr');
        is(scalar @rows, 3, 'external table has 3 rows (heading and 2 results)');
        my $res1
          = 'logpackages Some text result from external parser This is a dummy result to test rendering text results from external parsers.';
        my $res2
          = qr/logpackages Another text result from external parser Another dummy result to test rendering text results from external parsers\..*/;
        is($rows[1]->get_text(), $res1, 'first result displayed');
        like($rows[2]->get_text(), $res2, 'second result displayed');

        $driver->find_element_by_id('external-only-failed-filter')->click();
        @rows = $driver->find_child_elements($external_table, 'tr');
        is(scalar @rows, 2, 'passed results filtered out');
        is($rows[1]->get_text(), $res1, 'softfailure still displayed');
    };
};

subtest 'render video link if frametime is available' => sub {
    $driver->find_element_by_link_text('Details')->click();
    $driver->find_element('[href="#step/bootloader/1"]')->click();
    wait_for_ajax(msg => 'first step of bootloader test module loaded');
    my @links = $driver->find_elements('.step_actions .fa-file-video-o');
    is($#links, -1, 'no link without frametime');

    $driver->find_element('[href="#step/bootloader/2"]')->click();
    wait_for_ajax(msg => 'second step of bootloader test module loaded');
    my @video_link_elems = $driver->find_elements('.step_actions .fa-file-video-o');
    is($video_link_elems[0]->get_attribute('title'), 'Jump to video', 'video link exists');
    like(
        $video_link_elems[0]->get_attribute('href'),
        qr!/tests/99946/video\?filename=video\.ogv&t=0\.00,1\.00!,
        'video href correct'
    );
    $video_link_elems[0]->click();
    like(
        $driver->find_element('video')->get_attribute('src'),
        qr!/tests/99946/file/video\.ogv#t=0!,
        'video src correct and starts on timestamp'
    );
};

subtest 'misc details: title, favicon, go back, go to source view, go to log view' => sub {
    $driver->go_back();    # to 99946
    $driver->title_is('openQA: opensuse-13.1-DVD-i586-Build0091-textmode@32bit test results', 'tests/99946 followed');
    like($driver->find_element('link[rel=icon]')->get_attribute('href'),
        qr/logo-passed/, 'favicon is based on job result');
    wait_for_ajax(msg => 'test details tab for job 99946 loaded (1)');
    if (ok(my $current_preview = $driver->find_element('.current_preview'), 'state preserved when going back')) {
        $current_preview->click;
    }
    $driver->find_element_by_link_text('installer_timezone')->click();
    like(
        $driver->get_current_url(),
        qr{.*/tests/99946/modules/installer_timezone/steps/1/src$},
        'on src page for installer_timezone test'
    );
    is($driver->find_element('.cm-comment')->get_text(), '#!/usr/bin/env perl', 'we have a perl comment');

    # load "Logs & Assets" tab contents directly because accessing the tab within the whole page in a straight forward
    # way lead to unstability (see poo#94060)
    $driver->get('/tests/99946/downloads_ajax');
    like $driver->find_element_by_id('asset-list')->get_text,
      qr/openSUSE-13.1-DVD-i586-Build0091-Media.iso \(0 Byte\)[\n|\s]+openSUSE-13.1-x86_64.hda \(does not exist\)/,
      'asset list';
    $driver->find_element_by_link_text('autoinst-log.txt')->click;
    wait_for_ajax msg => 'log contents';
    like $driver->find_element('.embedded-logfile .ansi-blue-fg')->get_text, qr/send(autotype|key)/, 'log is colorful';
};

my $t = Test::Mojo->new('OpenQA::WebAPI');

subtest 'route to latest' => sub {
    $t->get_ok('/tests/latest?distri=opensuse&version=13.1&flavor=DVD&arch=x86_64&test=kde&machine=64bit')
      ->status_is(200);
    my $dom = $t->tx->res->dom;
    my $header = $dom->at('#info_box .card-header a');
    is($header->text, '99963', 'link shows correct test');
    is($header->{href}, '/tests/99963', 'latest link shows tests/99963');
    my $details_url = $dom->at('#details')->{'data-src'};
    is($details_url, '/tests/99963/details_ajax', 'URL for loading details via AJAX points to correct test');
    $t->get_ok($details_url)->status_is(200);
    is($t->tx->res->json->{modules}->[0]->{name}, 'isosize', 'correct first module');
    $t->get_ok('/tests/latest?flavor=DVD&arch=x86_64&test=kde')->status_is(200);
    $header = $t->tx->res->dom->at('#info_box .card-header a');
    is($header->{href}, '/tests/99963', '... as long as it is unique');
    $t->get_ok('/tests/latest?version=13.1')->status_is(200);
    $header = $t->tx->res->dom->at('#info_box .card-header a');
    is($header->{href}, '/tests/99982', 'returns highest job nr of ambiguous group');
    $t->get_ok('/tests/latest?test=kde&machine=32bit')->status_is(200);
    $dom = $t->tx->res->dom;
    $header = $dom->at('#info_box .card-header a');
    is($header->{href}, '/tests/99937', 'also filter on machine');
    my $job_groups_links = $dom->find('.navbar .dropdown a + ul.dropdown-menu a');
    my ($job_group_text, $build_text) = $job_groups_links->map('text')->each;
    my ($job_group_href, $build_href) = $job_groups_links->map('attr', 'href')->each;
    is($job_group_text, 'opensuse (current)', 'link to current job group overview');
    is($build_text, ' Build 0091', 'link to test overview');
    is($job_group_href, '/group_overview/1001', 'href to current job group overview');
    like($build_href, qr/distri=opensuse/, 'href to test overview');
    like($build_href, qr/groupid=1001/, 'href to test overview');
    like($build_href, qr/version=13.1/, 'href to test overview');
    like($build_href, qr/build=0091/, 'href to test overview');
    $t->get_ok('/tests/latest?test=foobar')->status_is(404);
};

# create 2 additional needle files for this particular test; fixtures are deleted in other tests
my $ntext = <<EOM;
{
  "area": [
    {
      "type": "match",
      "height": 42,
      "ypos": 444,
      "width": 131,
      "xpos": 381
    }
  ],
  "tags": [
      "sudo-passwordprompt",
      "some-other-tag"
  ]
}
EOM
$needle_dir->child("$_.json")->spurt($ntext) for qw(sudo-passwordprompt-lxde sudo-passwordprompt);

sub test_with_error {
    my ($needle_to_modify, $error, $tags, $expect, $test_name) = @_;

    # modify the fixture test data: parse JSON -> modify -> write JSON
    if (defined $needle_to_modify || defined $tags) {
        my $details_file = path('t/data/openqa/testresults/00099/'
              . '00099946-opensuse-13.1-DVD-i586-Build0091-textmode/details-yast2_lan.json');
        my $details = decode_json($details_file->slurp);
        my $detail = $details->[0];
        $detail->{needles}->[$needle_to_modify]->{error} = $error if defined $needle_to_modify && defined $error;
        $detail->{tags} = $tags if defined $tags;
        $details_file->spurt(encode_json($details));
    }

    # check whether candidates are displayed as expected
    my $random_number = int(rand(100000));
    $driver->get("/tests/99946?prevent_caching=$random_number#step/yast2_lan/1");
    wait_for_ajax_and_animations;
    is_deeply(find_candidate_needles, $expect, $test_name // 'candidates displayed as expected');
}

subtest 'test candidate list' => sub {
    test_with_error(undef, undef, [], {}, 'no tags at all');

    my %expected_candidates = (
        'this-tag-does-not-exist' => [],
        'sudo-passwordprompt' => ['63%: sudo-passwordprompt-lxde', '52%: sudo-passwordprompt'],
    );
    my @tags = sort keys %expected_candidates;
    test_with_error(undef, undef, \@tags, \%expected_candidates, '63%, 52%');
    # notes:
    # - some-other-tag is not in the list because the fixture test isn't looking for it
    # - this-tag-does-not-exist is in the list because the test is looking for it, even though
    #   no needle with the tag actually exists

    $expected_candidates{'sudo-passwordprompt'} = ['68%: sudo-passwordprompt-lxde', '52%: sudo-passwordprompt'];
    test_with_error(1, 0.1, \@tags, \%expected_candidates, '68%, 52%');
    $expected_candidates{'sudo-passwordprompt'} = ['100%: sudo-passwordprompt-lxde', '52%: sudo-passwordprompt'];
    test_with_error(1, 0, \@tags, \%expected_candidates, '100%, 52%');

    $expected_candidates{'sudo-passwordprompt'} = ['100%: sudo-passwordprompt', '100%: sudo-passwordprompt-lxde'];
    test_with_error(0, 0, \@tags, \%expected_candidates, '100%, 100%');

    # modify fixture tests to look for some-other-tag as well, needles should now appear twice
    %expected_candidates = (
        'sudo-passwordprompt' => $expected_candidates{'sudo-passwordprompt'},
        'some-other-tag' => $expected_candidates{'sudo-passwordprompt'},
    );
    test_with_error(0, 0, ['sudo-passwordprompt', 'some-other-tag'],
        \%expected_candidates, 'needles appear twice, each time under different tag');

    $driver->get('/tests/99946#step/installer_timezone/1');
    wait_for_ajax_and_animations(msg => 'step preview');
    $driver->find_element_by_id('candidatesMenu')->click();
    wait_for_element(selector => '#needlediff_selector .show-needle-info', is_displayed => 1)->click();
    like(
        $driver->find_element('.needle-info-table')->get_text(),
        qr/Last match.*T.*Last seen.*T.*/s,
        'last match and last seen shown',
    );
    $driver->find_element_by_id('candidatesMenu')->click();
    wait_until_element_gone('.needle-info-table');
};

# set job 99963 to done via API to tests whether worker is still displayed then
my $app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => '1234567890ABCDEF', apisecret => '1234567890ABCDEF')->ioloop(Mojo::IOLoop->singleton)
);
$t->app($app);
my $post
  = $t->post_ok($baseurl . 'api/v1/jobs/99963/set_done', form => {result => FAILED})->status_is(200, 'set job as done');
diag explain $t->tx->res->body unless $t->success;

$t->get_ok($baseurl . 'tests/99963')->status_is(200);
my @worker_text = $t->tx->res->dom->find('#assigned-worker')->map('all_text')->each;
like($worker_text[0], qr/[ \n]*Assigned worker:[ \n]*localhost:1[ \n]*/, 'worker still displayed when job set to done');
my @scenario_description = $t->tx->res->dom->find('#scenario-description')->map('all_text')->each;
like(
    $scenario_description[0],
    qr/[ \n]*Simple kde test, before advanced_kde[ \n]*/,
    'scenario description is displayed'
);

# now test the details of a job with nearly no settings which should yield no
# warnings
$t->get_ok('/tests/80000')->status_is(200);

subtest 'test module flags are displayed correctly' => sub {
    # for this job we have exactly each flag set once, so check that not to rely on the order of the test modules
    $driver->get('/tests/99764');
    wait_for_ajax(msg => 'details tab for job 99764 loaded');
    my $flags = $driver->find_elements("//div[\@class='flags']/i[(starts-with(\@class, 'flag fa fa-'))]", 'xpath');
    is(scalar(@{$flags}), 4, 'Expect 4 flags in the job 99764');

    my $flag = $driver->find_element("//div[\@class='flags']/i[\@class='flag fa fa-minus']", 'xpath');
    ok($flag, 'Ignore failure flag is displayed for test modules which are not important, neither fatal');
    is(
        $flag->get_attribute('title'),
        'Ignore failure: failure or soft failure of this test does not impact overall job result',
        'Description of Ignore failure flag is correct'
    );

    $flag = $driver->find_element("//div[\@class='flags']/i[\@class='flag fa fa-undo']", 'xpath');
    ok($flag, 'Always rollback flag is displayed correctly');
    is(
        $flag->get_attribute('title'),
        'Always rollback: revert to the last milestone snapshot even if test module is successful',
        'Description of always_rollback flag is correct'
    );

    $flag = $driver->find_element("//div[\@class='flags']/i[\@class='flag fa fa-anchor']", 'xpath');
    ok($flag, 'Milestone flag is displayed correctly');
    is(
        $flag->get_attribute('title'),
        'Milestone: snapshot the state after this test for restoring',
        'Description of milestone flag is correct'
    );

    $flag = $driver->find_element("//div[\@class='flags']/i[\@class='flag fa fa-plug']", 'xpath');
    ok($flag, 'Fatal flag is displayed correctly');
    is(
        $flag->get_attribute('title'),
        'Fatal: testsuite is aborted if this test fails',
        'Description of fatal flag is correct'
    );
};

subtest 'additional investigation notes provided on new failed' => sub {
    $driver->get('/tests/99947');
    wait_for_ajax(msg => 'details tab for job 99947 loaded to test investigation');
    $driver->find_element('#clones a')->click;
    $driver->find_element_by_link_text('Investigation')->click;
    ok($driver->find_element('table#investigation_status_entry')->text_like(qr/No result dir/),
        'investigation status content shown as table');
};

subtest 'alert box shown if not already on first bad' => sub {
    $driver->get('/tests/99940');
    wait_for_ajax(msg => 'details tab for job 99940 loaded to test investigation');
    $driver->find_element_by_link_text('Investigation')->click;
    $driver->find_element("//div[\@class='alert alert-info']", 'xpath')
      ->text_like(qr/Investigate the first bad test directly: 99938/);

    $driver->find_element_by_xpath("//div[\@class='alert alert-info']/a[\@class='alert-link']")->click;
    wait_for_ajax(msg => 'details tab for job 99938 loaded to test investigation');
    ok(
        $driver->find_element('table#investigation_status_entry')
          ->text_like(qr/error\nNo previous job in this scenario, cannot provide hints/),
        'linked to investigation tab directly'
    );
    $driver->find_element_by_xpath("//div[\@class='tab-content']")->text_unlike(qr/Investigate the first bad test/);
};

subtest 'archived icon' => sub {
    $t->get_ok('/tests/99947/infopanel_ajax')->status_is(200);
    is $t->tx->res->dom->find('#job-archived-badge')->size, 0, 'archived icon not shown by default';
    $jobs->find(99947)->update({archived => 1});
    $t->get_ok('/tests/99947/infopanel_ajax')->status_is(200);
    is $t->tx->res->dom->find('#job-archived-badge')->size, 1, 'archived icon shown if job is archived';
};

subtest 'test duration' => sub {
    my $start = DateTime->new(
        year => 2021,
        month => 9,
        day => 14,
        hour => 15,
        minute => 0,
        second => 0,
        nanosecond => 0,
        time_zone => 'UTC',
    );
    my $end = DateTime->new(
        year => 2021,
        month => 9,
        day => 16,
        hour => 17,
        minute => 30,
        second => 0,
        nanosecond => 0,
        time_zone => 'UTC',
    );
    my $duration = $t->app->format_time_duration($end - $start);
    like $duration, qr/2 days 02:30 hours/, 'duration formatted';
};

kill_driver();
done_testing();
