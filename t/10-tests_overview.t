# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '18';
use OpenQA::App;
use Date::Format 'time2str';
use Mojo::Parameters;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 05-job_modules.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $schema = $t->app->schema;

sub get_summary { OpenQA::Test::Case::trim_whitespace($t->tx->res->dom->at('#summary')->all_text) }

my $jobs = $schema->resultset('Jobs');

sub create_job {
    my %args = @_;
    return $jobs->create(
        {
            group_id => 1001,
            priority => 50,
            state => 'done',
            BUILD => '0001',
            ARCH => 'x86_64',
            MACHINE => '64bit',
            DISTRI => 'opensuse',
            VERSION => '13.1',
            FLAVOR => 'DVD',
            TEST => 'test',
            %args,
        });
}

$jobs->find(99928)->update({blocked_by_id => 99927});
$jobs->find($_)->comments->create({text => 'foobar', user_id => 99901}) for 99946, 99963;

subtest 'Basic overview display' => sub {
    $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1', build => '0091'})->status_is(200);

    my $summary = get_summary;
    like $summary, qr/Overall Summary of opensuse 13\.1 build 0091/i, 'Summary header shows distri, version and build';
    like $summary, qr/Passed: 3 Scheduled: 2 Running: 2 None: 1/i, 'Summary shows correct job counts per category';

    $t->element_exists('#flavor_DVD_arch_i586', 'header for flavor DVD arch i586 exists');
    $t->element_exists('#flavor_DVD_arch_x86_64', 'header for flavor DVD arch x86_64 exists');
    $t->element_exists('#flavor_GNOME-Live_arch_i686', 'header for flavor GNOME-Live arch i686 exists');
    $t->element_exists_not('#flavor_GNOME-Live_arch_x86_64', 'header for flavor GNOME-Live arch x86_64 does not exist');
    $t->element_exists_not('#flavor_DVD_arch_i686', 'header for flavor DVD arch i686 does not exist');

    $t->element_exists('#res_DVD_i586_kde .result_passed', 'passed result for DVD i586 kde exists');
    $t->element_exists('#res_GNOME-Live_i686_RAID0 i.state_cancelled',
        'cancelled state for GNOME-Live i686 RAID0 exists');
    $t->element_exists('#res_DVD_i586_RAID1 i.state_blocked', 'blocked state for DVD i586 RAID1 exists');
    $t->element_exists_not('#res_DVD_x86_64_doc', 'result for DVD x86_64 doc does not exist');

    my $dom = $t->tx->res->dom;
    is_deeply $dom->find('.status.state_scheduled')->map('parent')->map(attr => 'href')->to_array,
      ['/tests/99927'], '99927 is scheduled';
    is_deeply $dom->find('.status.state_blocked')->map('parent')->map(attr => 'href')->to_array,
      ['/tests/99928'], '99928 is blocked';
};

subtest 'Job group selection' => sub {
    my $form = {distri => 'opensuse', version => '13.1', build => '0091', group => 'opensuse 13.1'};
    $t->get_ok('/tests/overview' => form => $form)->status_is(200);
    like get_summary, qr/Overall Summary of opensuse 13\.1 build 0091/i, 'specifying group parameter';

    $form = {distri => 'opensuse', version => '13.1', build => '0091', groupid => 1001};
    $t->get_ok('/tests/overview' => form => $form)->status_is(200);
    like get_summary, qr/Overall Summary of opensuse build 0091/i, 'specifying groupid parameter';
};

subtest 'escaping works' => sub {
    my $form = {
        distri => '<img src="distri">',
        version => ['<img src="version1">', '<img src="version2">'],
        build => '<img src="build">'
    };
    $t->get_ok('/tests/overview' => form => $form)->status_is(200);
    my $body = $t->tx->res->body;
    unlike $body, qr/<img src="distri">/, 'no unescaped image tag for distri';
    unlike $body, qr/<img src="version1">.*<img src="version2">/, 'no unescaped image tags for version';
    unlike $body, qr/<img src="build">/, 'no unescaped image tag for build';
    like $body, qr/&lt;img src=&quot;distri&quot;&gt;/, 'image tag for distri escaped';
    like
      $body,
      qr/&lt;img src=&quot;version1&quot;&gt;.*&lt;img src=&quot;version2&quot;&gt;/,
      'image tags for version escaped';
    like $body, qr/&lt;img src=&quot;build&quot;&gt;/, 'image tag for build escaped';
};

subtest 'Overview of build 0048' => sub {
    $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '0048'})
      ->status_is(200);
    like get_summary, qr/\QSoft-Failed: 2 Failed: 1\E/i, 'Summary shows correct counts for build 0048';

    $t->element_exists('#flavor_DVD_arch_x86_64', 'header for DVD x86_64 exists');
    $t->element_exists_not('#flavor_DVD_arch_i586', 'header for DVD i586 does not exist');
    $t->element_exists_not('#flavor_GNOME-Live_arch_i686', 'header for GNOME-Live i686 does not exist');

    $t->element_exists('#res_DVD_x86_64_doc .result_failed', 'failed result for DVD x86_64 doc exists');
    $t->element_exists('#res_DVD_x86_64_kde .result_softfailed', 'softfailed result for DVD x86_64 kde exists');
    $t->element_exists_not('#res_DVD_i586_doc', 'result for DVD i586 doc does not exist');
    $t->element_exists_not('#res_DVD_i686_doc', 'result for DVD i686 doc does not exist');

    $t->text_is('#res_DVD_x86_64_doc .failedmodule *' => 'logpackages', 'failed modules are listed');
};

subtest 'Default overview for 13.1' => sub {
    $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1'})->status_is(200);
    my $summary = get_summary;
    like $summary, qr/Summary of opensuse 13\.1 build 0091/i, 'Default build for 13.1 is 0091';
    like $summary, qr/Passed: 3 Scheduled: 2 Running: 2 None: 1/i, 'Counts for 13.1 build 0091 match';

    my $form = {distri => 'opensuse', version => '13.1', groupid => 1001};
    $t->get_ok('/tests/overview' => form => $form)->status_is(200);
    like get_summary, qr/Summary of opensuse build 0091/i,
      'specifying groupid without build yields latest build in group';

    sub flash_msg { $t->tx->res->dom->at('#flash-messages')->all_text }
    unlike flash_msg, qr/Specified "groupid" is invalid/i, 'no error message for valid groupid';

    $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1', groupid => 'a'})->status_is(200);
    like flash_msg, qr/Specified "groupid" is invalid/i, 'error message for invalid groupid';
};

subtest 'Default overview for Factory' => sub {
    $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory'})->status_is(200);
    my $summary = get_summary;
    like $summary, qr/Summary of opensuse Factory build 0048\@0815/i, 'Default build for Factory is 0048@0815';
    like $summary, qr/\QFailed: 1\E/i, 'Count for Factory build 0048@0815 matches';
};

subtest 'Check old build' => sub {
    $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '87.5011'})
      ->status_is(200);
    my $summary = get_summary;
    like $summary, qr/Summary of opensuse Factory build 87.5011/, 'Can still view old build 87.5011';
    like $summary, qr/Incomplete: 1/, 'Count for build 87.5011 matches';
};

subtest 'time parameter' => sub {
    $jobs->find(99926)->update({clone_id => 99927});

    my $link_to_fixed = $t->tx->res->dom->at('#summary .time-params a');
    if (isnt $link_to_fixed, undef, 'link to "fixed" present') {
        my $params = Mojo::Parameters->new(substr $link_to_fixed->attr('href') // '', 1);
        my $validation = $t->app->validator->validation->input($params->to_hash);
        ok $validation->required('t')->datetime->is_valid, 'link to "fixed" has valid time param';
    }
    my $summary = get_summary;
    like $summary, qr/showing latest jobs, overview fixed to the current time/, 'info without time param';

    my @params = (distri => 'opensuse', version => 'Factory', build => '87.5011');
    my $tp = '2020-01-01T00:00:00';
    $t->get_ok('/tests/overview' => form => {@params, t => $tp});
    like get_summary, qr/at the time of $tp.*show latest jobs/s, 'jobs newer than time parameter filtered out';
    $t->get_ok('/tests/overview' => form => {@params, t => time2str('%Y-%m-%d %H:%M:%S', time, 'UTC')});
    like get_summary, qr/at the time of.*show latest.*Incomplete: 1/s, 'jobs newer than time parameter shown';
};

subtest 'limit parameter' => sub {
    $t->get_ok('/tests/overview?distri=opensuse&version=Factory&build=0048&limit=2&limit=2',
        'no database error when specifying more than one limit');
    is $t->tx->res->dom->find('table.overview td.name')->size, 2, 'number of jobs limited to 2';
};

subtest 'Advanced query parameters' => sub {
    my $form = {distri => 'opensuse', version => '13.1', result => 'passed'};
    $t->get_ok('/tests/overview' => form => $form)->status_is(200);
    my $summary = get_summary;
    like $summary, qr/Summary of opensuse 13\.1 build 0091/i,
      'Still references the last build when filtering by result';
    like $summary, qr/Passed: 3/i, 'only passed are shown in summary';
    $t->element_exists('#res_DVD_i586_kde .result_passed', 'passed result shown');
    $t->element_exists('#res_DVD_i586_textmode .result_passed', 'another passed result shown');
    $t->element_exists_not('#res_DVD_i586_RAID0 .state_scheduled', 'scheduled job hidden');
    $t->element_exists_not('#res_DVD_x86_64_kde .state_running', 'running job hidden');
    $t->element_exists_not('#res_GNOME-Live_i686_RAID0 .state_cancelled', 'cancelled job hidden');
    $t->element_exists_not('.result_failed', 'failed results hidden');
    $t->element_exists_not('.state_cancelled', 'cancelled states hidden');

    $form = {distri => 'opensuse', version => 'Factory', build => '0048', result => 'failed'};
    $t->get_ok('/tests/overview' => form => $form)->status_is(200);
    like get_summary, qr/current time Failed: 1/i, 'only failed shown in summary for build 0048';
    $t->element_exists('#res_DVD_x86_64_doc .result_failed', 'failed result shown');
    $t->element_exists_not('#res_DVD_x86_64_kde .result_passed', 'passed result hidden');
};

subtest 'summary card border' => sub {
    my $softfailed_job = create_job(
        result => OpenQA::Jobs::Constants::SOFTFAILED,
        TEST => 'softfailed_test',
        VERSION => 'SoftFailVersion',
        DISTRI => 'softfail_distri',
    );

    $t->get_ok('/tests/overview' => form => {distri => 'softfail_distri', version => 'SoftFailVersion'})
      ->status_is(200);
    $t->element_exists('#summary.border-success', 'softfailed results in border-success');
    $t->element_exists_not('#summary.border-danger', 'softfailed does NOT result in border-danger');

    my $failed_job = create_job(
        result => OpenQA::Jobs::Constants::FAILED,
        TEST => 'failed_test',
        VERSION => 'SoftFailVersion',
        DISTRI => 'softfail_distri',
    );

    $t->get_ok('/tests/overview' => form => {distri => 'softfail_distri', version => 'SoftFailVersion'})
      ->status_is(200);
    $t->element_exists('#summary.border-danger', 'failed + softfailed results in border-danger');

    $softfailed_job->delete();
    $failed_job->delete();
};

subtest 'clickable summary buttons' => sub {
    $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '0048'})
      ->status_is(200);
    my $summary = $t->tx->res->dom->at('#summary .card-body');
    my $failed_link = $summary->at('a[href*="result=failed"]');
    ok $failed_link, 'Failed count is clickable';
    my $href = $failed_link->attr('href');
    like $href, qr/distri=opensuse/, 'link preserves distri';
    like $href, qr/version=Factory/, 'link preserves version';
    like $href, qr/build=0048/, 'link preserves build';
    like $href, qr/result=failed/, 'link sets result filter';

    my $softfailed_link = $summary->at('a[href*="result=softfailed"]');
    ok $softfailed_link, 'Soft-failed count is clickable';
    like $softfailed_link->attr('href'), qr/result=softfailed/, 'link sets softfailed filter';

    $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1'})->status_is(200);
    $summary = $t->tx->res->dom->at('#summary .card-body');
    my $passed_link = $summary->at('a[href*="result=passed"]');
    ok $passed_link, 'Passed count is clickable for 13.1';
    like $passed_link->attr('href'), qr/result=passed/, 'link sets passed filter';

    my $all_link = $summary->at('a:last-child');
    is $all_link->text, 'All', 'All button is present';
    unlike $all_link->attr('href'), qr/result=/, 'All button clears result filter';
};

subtest 'todo-flag on test overview' => sub {
    $schema->txn_begin;
    create_job(
        id => 99964,
        BUILD => '0048',
        TEST => 'server_client_parallel',
        VERSION => 'Factory',
        result => 'parallel_failed',
    );
    my $form = {distri => 'opensuse', version => 'Factory', build => '0048', todo => 1};
    $t->get_ok('/tests/overview' => form => $form)->status_is(200);
    like get_summary, qr/current time Failed: 1/i, 'todo=1 shows only unlabeled left failed';

    for my $j ((99936, 99964)) {
        $schema->resultset('JobModules')->create(
            {
                script => 'tests/x11/failing_module.pm',
                job_id => $j,
                category => 'x11',
                name => 'failing_module',
                result => 'failed'
            });
    }

    $t->get_ok('/tests/overview' => form => $form)->status_is(200);
    like
      get_summary,
      qr/current time Soft-Failed: 1 Failed: 1 Aborted: 1/i,
      'todo=1 shows unlabeled left failed (previously softfailed)';
    $t->element_exists_not('#res-99939', 'softfailed filtered out');
    $t->element_exists('#res-99936', 'unreviewed failed because of new failing module present');

    $schema->resultset('Comments')->create(
        {
            job_id => 99936,
            text => 'bsc#1234',
            user_id => 99903,
        });
    $t->get_ok('/tests/overview' => form => $form)->status_is(200);
    like get_summary, qr/current time Failed: 1 Aborted: 1/i, 'todo=1 shows only unlabeled left failed after labelling';
    $t->element_exists_not('#res-99936', 'reviewed failed filtered out');
    $schema->txn_rollback;
};

subtest 'Multiple groups display' => sub {
    $t->get_ok('/tests/overview?distri=opensuse&version=13.1&groupid=1001&groupid=1002&build=0091')->status_is(200);
    my $summary = get_summary;
    like $summary, qr/Summary of opensuse\s*,\s*opensuse test/i, 'references both groups selected by query';
    like
      $summary,
      qr/current time Passed: 2 Scheduled: 1 Running: 2 None: 1/i,
      'shows latest jobs from both groups 1001/1002';
    $t->element_exists('#res_DVD_i586_kde', 'job from group 1001 is shown');
    $t->element_exists('#res_GNOME-Live_i686_RAID0 .state_cancelled', 'another job from group 1001');
    $t->element_exists('#res_NET_x86_64_kde .state_running', 'job from group 1002 is shown');

    $t->get_ok('/tests/overview?distri=opensuse&version=13.1&groupid=1001&groupid=1002')->status_is(200);
    $summary = get_summary;
    like
      $summary,
      qr/Summary of opensuse\s*,\s*opensuse test build 0091[^,]/i,
      'multiple groups with no build specified yield the same, latest build of every group';
    like $summary, qr/current time Passed: 2 Scheduled: 1 Running: 2 None: 1/i;

    my $jobGroup = $schema->resultset('JobGroups')->create(
        {
            id => 1003,
            sort_order => 0,
            name => 'opensuse test 2'
        });

    my $job = create_job(
        id => 99964,
        BUILD => '0092',
        group_id => 1003,
        TEST => 'kde',
        state => 'scheduled',
    );

    $t->get_ok('/tests/overview?distri=opensuse&version=13.1&groupid=1001&groupid=1003')->status_is(200);
    $summary = get_summary;
    like
      $summary,
      qr/Summary of opensuse\s*,\s*opensuse test 2 build 0091,0092/i,
      'multiple groups with no build specified yield each build for every group';
    like $summary, qr/current time Passed: 3 Scheduled: 2 Running: 1 None: 1/i, 'summary of 0091,0092 counts match';

    $t->get_ok('/tests/overview?arch=&flavor=&machine=&test=&modules=kate&module_re=&groupid=1001')->status_is(200);
    $summary = get_summary;
    like
      $summary,
      qr/Overall Summary of opensuse showing latest jobs, overview fixed to the current time/i,
      'complex query based on poo#98258 finds jobs with selected module';
    like $summary, qr/Passed: 1 Failed: 1 Running: 1/i;

    $jobGroup->delete();
    $job->delete();
};

subtest 'Generic overview search' => sub {
    $t->get_ok('/tests/overview' => form => {build => '0091', version => '13.1'})->status_is(200);
    $t->get_ok('/tests/overview' => form => {build => '0091', distri => 'opensuse'})->status_is(200);
    $t->get_ok('/tests/overview' => form => {build => '0091'})->status_is(200);
    $t->get_ok('/tests/overview')->status_is(200);
    my $summary = get_summary;
    like $summary, qr/Summary of opensuse/i, 'shows all available latest jobs for the only present distri';
    like
      $summary,
      qr/current time Passed: 3 Scheduled: 2 Running: 2 None: 1/i,
      'shows latest jobs from all distri, version, build, flavor, arch';
    $t->element_exists('#res_DVD_i586_kde', 'passed DVD i586 kde job shown');
    $t->element_exists('#res_GNOME-Live_i686_RAID0 .state_cancelled', 'cancelled GNOME-Live i686 RAID0 job shown');
    $t->element_exists('#res_NET_x86_64_kde .state_running', 'running NET x86_64 kde job shown');
};

subtest 'Incomplete result accounting' => sub {
    $schema->txn_begin;
    $jobs->search({id => 99937})->update({result => OpenQA::Jobs::Constants::INCOMPLETE});
    $jobs->search({id => 99946})->update({result => OpenQA::Jobs::Constants::TIMEOUT_EXCEEDED});
    $jobs->search({id => 99764})->update({result => OpenQA::Jobs::Constants::USER_CANCELLED});

    $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1'})->status_is(200);
    like get_summary, qr/\QIncomplete: 2 Scheduled: 2 Running: 2 Aborted: 1 None: 1/i,
      'INCOMPLETE and TIMEOUT_EXCEEDED accounted as incomplete';
    $schema->txn_rollback;
};

subtest 'Filter by module failures' => sub {
    $t->get_ok('/tests/999379999/modules/kate/fails')->status_is(404, '404 when test does not exist');
    $t->get_ok('/tests/99937/modules/kate/fails')
      ->json_is('/failed_needles' => ['test-kate-1'], 'correct failed needles returned');
    $t->get_ok('/tests/99937/modules/zypper_up/fails')
      ->json_is('/first_failed_step' => 1, 'fallback to first step for failed module');

    my $form = {distri => 'opensuse', version => 'Factory', failed_modules => 'logpackages'};
    $t->get_ok('/tests/overview', form => $form)->status_is(200);
    like get_summary, qr/current time/i, 'no jobs shown when filtering by failing module that was not the latest';
    $t->element_exists_not('#res_DVD_x86_64_doc .result_failed', 'old job not revealed');
    $t->element_exists_not('#res_DVD_x86_64_kde .result_passed', 'passed job hidden');

    my $latest_job = $jobs->find(99940);
    $latest_job->update({DISTRI => 'not opensuse'});
    $t->get_ok('/tests/overview', form => $form)->status_is(200);
    like get_summary, qr/current time Failed: 1/i, 'job with failed module logpackages shown when it is the latest';
    $t->element_exists('#res_DVD_x86_64_doc .result_failed', 'correct job shown');
    $t->element_exists_not('#res_DVD_x86_64_kde .result_passed', 'passed job hidden');

    $latest_job->update({DISTRI => 'opensuse'});
    my $failing_module = $schema->resultset('JobModules')->create(
        {
            script => 'tests/x11/failing_module.pm',
            job_id => 99940,
            category => 'x11',
            name => 'failing_module',
            result => 'failed'
        });
    $t->get_ok(
        '/tests/overview' => form => {
            distri => 'opensuse',
            version => 'Factory',
            failed_modules => 'failing_module'
        })->status_is(200);

    like get_summary, qr/current time Failed: 1/i, 'failed_modules parameter finds failed jobs';
    $t->element_exists('#res-99940', 'job with custom failing module exists');

    $schema->resultset('JobModules')->create(
        {
            script => 'tests/x11/failing_module.pm',
            job_id => 99938,
            category => 'x11',
            name => 'failing_module',
            result => 'failed'
        });
    $t->get_ok(
        '/tests/overview' => form => {
            distri => 'opensuse',
            version => 'Factory',
            failed_modules => 'failing_module,logpackages',
        })->status_is(200);
    like get_summary, qr/current time Failed: 1/i, 'filtering by multiple failed modules works';
    $t->text_is('#res_DVD_x86_64_doc .failedmodule *' => 'failing_module', 'correct failed module name shown');

    $schema->resultset('JobModules')->create(
        {
            script => 'tests/x11/failing_module.pm',
            job_id => 99946,
            category => 'x11',
            name => 'failing_module',
            result => 'failed'
        });
    $t->get_ok(
        '/tests/overview' => form => {
            distri => 'opensuse',
            version => '13.1',
            failed_modules => 'failing_module',
        })->status_is(200);
    like get_summary, qr/current time/i, 'Successful job with fake module failure not shown by failed_modules';
    $t->element_exists_not('#res-99946', 'job 99946 is hidden');
};

subtest 'comment parameter' => sub {
    $t->get_ok('/tests/overview?groupid=1001&distri=opensuse&version=13.1&build=0091&comment=oob');
    $t->status_is(200);
    my $ids = $t->tx->res->dom->find('.overview span[id^="res-"]')->map(attr => 'id')->sort->to_array;
    is_deeply $ids, [qw(res-99946 res-99963)], 'filtering by comment text returns expected jobs';
};

subtest 'Inverted filters' => sub {
    $t->get_ok('/tests/overview?distri=opensuse&version=13.1&build=0091&result__not=passed')->status_is(200);
    my $summary = get_summary;
    unlike $summary, qr/Passed: [1-9]/i, 'Passed jobs are excluded via result__not';
    like $summary, qr/Scheduled: 2 Running: 2 None: 1/i, 'Other categories remain';

    $t->get_ok('/tests/overview?distri=opensuse&version=Factory&build=0048&result__not=failed&result__not=softfailed')
      ->status_is(200);
    $summary = get_summary;
    unlike $summary, qr/Failed: [1-9]/i, 'Failed jobs are excluded via multiple result__not';
    unlike $summary, qr/Soft-Failed: [1-9]/i, 'Soft-failed jobs are excluded via multiple result__not';

    $t->get_ok('/tests/overview?distri=opensuse&version=13.1&build=0091&state__not=done')->status_is(200);
    $summary = get_summary;
    unlike $summary, qr/Passed: [1-9]/i, 'Done jobs (passed) are excluded via state__not=done';
    like $summary, qr/Scheduled: 2 Running: 2/i, 'Scheduled and running remain';

    $t->get_ok('/tests/overview?distri=opensuse&version=13.1&build=0091&state__not=done&state__not=running')
      ->status_is(200);
    $summary = get_summary;
    unlike $summary, qr/Passed: [1-9]/i, 'Done jobs excluded';
    unlike $summary, qr/Running: [1-9]/i, 'Running jobs excluded';
    like $summary, qr/Scheduled: 2/i, 'Only scheduled jobs remain';
};

subtest 'Filtering by job settings' => sub {
    $schema->txn_begin;
    my @basic_settings = (VERSION => 'test_version', DISTRI => 'test_distri');
    my @search_params = (distri => 'test_distri', version => 'test_version', job_setting => ());
    my @jobs = (create_job(TEST => 'test_job_1', @basic_settings), create_job(TEST => 'test_job_2', @basic_settings));
    $jobs[0]->settings->create({key => 'MY_SETTING', value => 'my_value'});
    $jobs[0]->settings->create({key => 'ANOTHER_SETTING', value => 'another_value'});
    $jobs[1]->settings->create({key => 'MY_SETTING', value => 'other_value'});
    $jobs[1]->settings->create({key => 'ANOTHER_SETTING', value => 'another_value'});
    $jobs[1]->settings->create({key => 'ANOTHER_SETTING', value => 'yet_another_value'});

    $t->get_ok('/tests/overview', form => {@search_params, 'MY_SETTING=my_value'})->status_is(200);
    $t->element_exists('#res-' . $jobs[0]->id, 'job with custom setting found');
    $t->element_exists_not('#res-' . $jobs[1]->id, 'job with different setting hidden');

    $t->get_ok('/tests/overview', form => {@search_params, 'MY_SETTING=different_value'})->status_is(200);
    $t->element_exists_not('#res-' . $_->id, 'all jobs filtered out by non-matching setting') for @jobs;

    $t->get_ok('/tests/overview', form => {@search_params, ['MY_SETTING=my_value', 'ANOTHER_SETTING=another_value']});
    $t->status_is(200, 'can filter by more than one job setting');
    $t->element_exists('#res-' . $jobs[0]->id, 'job with multiple matching settings found');
    $t->element_exists_not('#res-' . $jobs[1]->id, 'job with partial match hidden');

    $t->get_ok('/tests/overview', form => {@search_params, [map { "ANOTHER_SETTING=${_}another_value" } '', 'yet_']});
    $t->status_is(200, 'can filter by the same job setting multiple times');
    $t->element_exists_not('#res-' . $jobs[0]->id, 'job with single match hidden when multiple required');
    $t->element_exists('#res-' . $jobs[1]->id, 'job with multiple required setting values found');

    $schema->txn_rollback;
};

subtest 'Meta-filters' => sub {
    $t->get_ok('/tests/overview?distri=opensuse&version=13.1&build=0091&result=complete')->status_is(200);
    my $summary = get_summary;
    like $summary, qr/Passed: 3/i, 'Passed jobs included via "complete" meta-result';

    $t->get_ok('/tests/overview?distri=opensuse&version=13.1&build=0091&state=final')->status_is(200);
    $summary = get_summary;
    like $summary, qr/Passed: 3/i, 'Done jobs included via "final" meta-state';

    $t->get_ok('/tests/overview?distri=opensuse&version=13.1&build=0091&result__not=complete')->status_is(200);
    $summary = get_summary;
    unlike $summary, qr/Passed: [1-9]/i, 'Passed jobs excluded via result__not=complete';
    like $summary, qr/Scheduled: 2 Running: 2/i, 'Other categories remain';
};

subtest 'Maximum jobs limit' => sub {
    $t->get_ok('/tests/overview')->status_is(200)
      ->element_exists_not('#max-jobs-limit', 'Limit warning hidden by default');
    local OpenQA::App->singleton->config->{misc_limits}->{tests_overview_max_jobs} = 2;
    $t->get_ok('/tests/overview')->status_is(200)
      ->element_exists('#max-jobs-limit', 'Limit warning shown when exceeded');
    $t->text_like('#max-jobs-limit', qr/Only 2 results included/, 'Warning text contains correct limit');
    is $t->tx->res->dom->find('table.overview td.name')->size, 2, 'Number of displayed jobs limited';

    $t->get_ok('/tests/overview?result=incomplete')->status_is(200)
      ->element_exists_not('#max-jobs-limit', 'Warning hidden when result count is below limit');
};

subtest 'aggregate favicon' => sub {
    $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1', build => '0091'})->status_is(200);
    $t->element_exists('link#favicon-16[href*="logo-aggregate-running-16.png"]', 'running favicon (16x16) exists');
    $t->element_exists('link#favicon-svg[href*="logo-aggregate-running.svg"]', 'running favicon (svg) exists');

    $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '0048'})
      ->status_is(200);
    $t->element_exists('link#favicon-16[href*="logo-aggregate-failed-16.png"]', 'failed favicon (16x16) exists');
    $t->element_exists('link#favicon-svg[href*="logo-aggregate-failed.svg"]', 'failed favicon (svg) exists');

    $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1', result => 'passed'})
      ->status_is(200);
    $t->element_exists('link#favicon-16[href*="logo-aggregate-passed-16.png"]', 'passed favicon (16x16) exists');
    $t->element_exists('link#favicon-svg[href*="logo-aggregate-passed.svg"]', 'passed favicon (svg) exists');
};

subtest 'Job group filtering and truncation' => sub {
    $t->get_ok('/tests/overview?build=87.5011&groupid=1001&groupid=1002&distri=opensuse&version=Factory')
      ->status_is(200);
    my $summary = get_summary();
    like $summary, qr/Summary of opensuse\s+Factory build 87.5011/i, 'Summary header shows group with results';
    unlike $summary, qr/opensuse test/i, 'Summary header excludes group with no results for build';

    for my $i (1 .. 10) {
        my $g = $schema->resultset('JobGroups')->create({name => "Extra Group $i"});
        $schema->resultset('Jobs')->create(
            {
                group_id => $g->id,
                priority => 50,
                state => 'done',
                BUILD => '0091',
                DISTRI => 'opensuse',
                VERSION => '13.1',
                ARCH => 'x86_64',
                MACHINE => '64bit',
                FLAVOR => 'DVD',
                TEST => "test_$i",
            });
    }

    $t->get_ok('/tests/overview?build=0091&group_glob=*')->status_is(200);
    my $dom = $t->tx->res->dom;

    is $dom->find('.more-groups')->size, 12 - 7,
      'Correct number of groups are hidden (12 groups total, 7 shown by default)';
    $t->element_exists('#show-more-groups', 'Ellipsis for more groups exists');
    is $dom->at('#show-more-groups')->text, "\x{2026}", 'Ellipsis button uses proper unicode character';
};

subtest 'restart counter' => sub {
    my $orig = create_job(TEST => 'restart_test', BUILD => '198077');
    my $clone = $orig->auto_duplicate();
    ok ref $clone, "Job cloned successfully: $clone" or BAIL_OUT 'Failed to clone job';
    $clone->update({state => 'done', result => 'passed'});
    $t->get_ok('/tests/overview' => form => {build => '198077'})->status_is(200);
    $t->content_like(qr/fa-undo/i, 'Overview contains restart icon');
    $t->content_like(qr/title="Restarted 1 time"/i, 'Overview contains restart title');
    create_job(BUILD => '198077_norestart', TEST => 'no_restart_test');
    $t->get_ok('/tests/overview' => form => {build => '198077_norestart'})->status_is(200);
    $t->content_unlike(qr/fa-undo/i, 'Overview does not contain restart icon for job with no restarts');
    my $clone2 = $clone->auto_duplicate();
    ok ref $clone2, "Job 2 cloned successfully: $clone2" or BAIL_OUT 'Failed to clone job 2';
    $clone2->update({state => 'done', result => 'passed'});
    $t->get_ok('/tests/overview' => form => {build => '198077'})->status_is(200);
    $t->content_like(qr/title="Restarted 2 times"/i, 'Overview contains 2 restarts title');
    $t->content_like(qr/<i class="fa fa-undo"><\/i> 2/i, 'Overview contains restart count 2');
    $t->get_ok('/tests/list_ajax' => form => {limit => 100})->status_is(200);
    my $data = Mojo::JSON::decode_json($t->tx->res->body)->{data};
    my ($clone2_data) = grep { $_->{id} == $clone2->id } @$data;
    is $clone2_data->{restarts}, 2, 'AJAX list contains restart count 2';
};

done_testing();
