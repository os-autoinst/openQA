# Copyright (C) 2016 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

# see also t/ui/14-dashboard.t and t/ui/14-dashboard-parents.t for PhantomJS test

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use JSON qw(decode_json);

# init test case
my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $auth = {'X-CSRF-Token' => $t->ua->get('/tests')->res->dom->at('meta[name=csrf-token]')->attr('content')};
$test_case->login($t, 'percival');
my $job_groups    = $t->app->db->resultset('JobGroups');
my $parent_groups = $t->app->db->resultset('JobGroupParents');
my $jobs          = $t->app->db->resultset('Jobs');

# regular job groups shown
my $get = $t->get_ok('/')->status_is(200);
my @h2  = $get->tx->res->dom->find('h2 a')->map('text')->each;
is_deeply(\@h2, ['opensuse', 'opensuse test'], 'two groups shown (from fixtures)');

# create (initially) empty parent group
my $test_parent = $parent_groups->create({name => 'Test parent', sort_order => 2});

$get = $t->get_ok('/')->status_is(200);
@h2  = $get->tx->res->dom->find('h2 a')->map('text')->each;
is_deeply(\@h2, ['opensuse', 'opensuse test'], 'empty parent group not shown');

# move opensuse group to new parent group
my $opensuse_group = $job_groups->find({name => 'opensuse'});
$opensuse_group->update({parent_id => $test_parent->id});

$get = $t->get_ok('/group_overview/' . $opensuse_group->id)->status_is(200);
@h2  = $get->tx->res->dom->find('h2')->map('all_text')->each;
like(
    $h2[0],
    qr/[ \n]*Last Builds for[ \n]*Test parent[ \n]*\/[ \n]*opensuse[ \n]*/,
    'parent name also shown on group overview'
);

$get = $t->get_ok('/')->status_is(200);
@h2  = $get->tx->res->dom->find('h2 a')->map('text')->each;
is_deeply(\@h2, ['opensuse test', 'Test parent'], 'parent group shown and opensuse is no more on top-level');

my @h4 = $get->tx->res->dom->find('div.children-collapsed h4 a')->map('text')->each;
is_deeply(\@h4, [qw(Build87.5011 Build0048@0815 Build0048)], 'builds on parent-level shown, sorted first by version');
@h4 = $get->tx->res->dom->find('div.collapse h4 a')->map('text')->each;
is_deeply(\@h4, ['opensuse', 'opensuse', 'opensuse'], 'opensuse now shown as child group (for each build)');

# check build limit
$get = $t->get_ok('/?limit_builds=2')->status_is(200);
@h4  = $get->tx->res->dom->find('div.children-collapsed h4 a')->map('text')->each;
is_deeply(\@h4, [qw(Build87.5011 Build0048@0815)], 'builds on parent-level shown (limit builds)');
@h4 = $get->tx->res->dom->find('div.collapse h4 a')->map('text')->each;
is_deeply(\@h4, ['opensuse', 'opensuse'], 'opensuse now shown as child group (limit builds)');

# also add opensuse test to parent to actually check the grouping
my $opensuse_test_group = $job_groups->find({name => 'opensuse test'});
$opensuse_test_group->update({parent_id => $test_parent->id});

# and add review for build 0048@0815
$opensuse_group->jobs->find({BUILD => '0048@0815'})->comments->create({text => 'poo#1234', user_id => 99901});

$get = $t->get_ok('/?limit_builds=20&show_tags=1')->status_is(200);
@h2  = $get->tx->res->dom->find('h2 a')->map('text')->each;
is_deeply(\@h2, ['Test parent'], 'only parent shown, no more top-level job groups');

sub check_test_parent {
    my ($default_expanded) = @_;

    @h4 = $get->tx->res->dom->find("div.children-$default_expanded h4 a")->map('text')->each;
    is_deeply(
        \@h4,
        ['Build87.5011', 'Build0048@0815', 'Build0048', 'Build0092', 'Build0091'],
        'builds on parent-level shown'
    );

    $t->element_count_is('#review-' . $test_parent->id . '-Factory-0048_0815',
        1, 'review badge for build 0048@0815 shown');
    $t->element_count_is('#child-review-' . $test_parent->id . '-Factory-0048_0815',
        1, 'review badge for build 0048@0815 also shown on child-level');
    $t->element_count_is('#review-' . $test_parent->id . '-0048', 0, 'review badge for build 0048 NOT shown yet');
    $t->element_count_is('#child-review-' . $test_parent->id . '-0048',
        0, 'review badge for build 0048 also on child-level NOT shown yet');

    my @progress_bars
      = $get->tx->res->dom->find("div.children-$default_expanded .progress")->map('attr', 'title')->each;
    is_deeply(
        \@progress_bars,
        [
            "failed: 1\ntotal: 1",
            "failed: 1\ntotal: 1",
            "softfailed: 2\nfailed: 1\ntotal: 3",
            "passed: 1\ntotal: 1",
            "passed: 2\nunfinished: 3\nskipped: 1\ntotal: 6",
        ],
        'parent-level progress bars are accumulated'
    );

    @h4 = $get->tx->res->dom->find('div#group' . $test_parent->id . '_build13_1-0091 h4 a')->map('text')->each;
    is_deeply(\@h4, ['opensuse', 'opensuse test'], 'both child groups shown under common build');
    @progress_bars
      = $get->tx->res->dom->find('div#group' . $test_parent->id . '_build13_1-0091 .progress')->map('attr', 'title')
      ->each;
    is_deeply(
        \@progress_bars,
        ["passed: 2\nunfinished: 2\nskipped: 1\ntotal: 5", "unfinished: 1\ntotal: 1"],
        'progress bars for child groups shown correctly'
    );

    my @urls
      = $get->tx->res->dom->find('div#group' . $test_parent->id . '_build13_1-0091 h4 a')->map('attr', 'href')->each;
    is_deeply(
        \@urls,
        [
            '/tests/overview?distri=opensuse&version=13.1&build=0091&groupid=1001',
            '/tests/overview?distri=opensuse&version=13.1&build=0091&groupid=1002'
        ],
        'link URLs'
    );

    $t->element_count_is("div.children-$default_expanded .badge-all-passed", 1, 'badge shown on parent-level');
    $t->element_count_is("div.children-$default_expanded h4 span i.tag",     0, 'no tags shown yet');
}
check_test_parent('collapsed');

# links are correct
my @urls = $get->tx->res->dom->find('h2 a, .row a')->map('attr', 'href')->each;
for my $url (@urls) {
    next if ($url =~ /^#/);
    $get = $t->get_ok($url)->status_is(200);
}

# parent group overview
$get = $t->get_ok('/parent_group_overview/' . $test_parent->id)->status_is(200);
check_test_parent('expanded');

# add tags (99901 is user ID of arthur)
my $tag_for_0092_comment = $opensuse_group->comments->create({text => 'tag:0092:important:some_tag', user_id => 99901});

sub check_tags {
    $get = $t->get_ok('/?limit_builds=20&show_tags=1')->status_is(200);
    my @tags = $get->tx->res->dom->find('div.children-collapsed h4 span i.tag')->map('text')->each;
    is_deeply(\@tags, ['some_tag'], 'tag is shown on parent-level');

    $get  = $t->get_ok('/parent_group_overview/' . $test_parent->id . '?limit_builds=20&show_tags=1')->status_is(200);
    @tags = $get->tx->res->dom->find('div.children-expanded h4 span i.tag')->map('text')->each;
    is_deeply(\@tags, ['some_tag'], 'tag is shown on parent-level');

    $get  = $t->get_ok('/?limit_builds=20&only_tagged=1')->status_is(200);
    @tags = $get->tx->res->dom->find('div.children-collapsed h4 span i.tag')->map('text')->each;
    is_deeply(\@tags, ['some_tag'], 'tag is shown on parent-level (only tagged)');
    @h4 = $get->tx->res->dom->find("div.children-collapsed h4 a")->map('text')->each;
    is_deeply(\@h4, ['Build0092'], 'only tagged builds on parent-level shown');
}
check_tags();

# use version-build format where version matches
$tag_for_0092_comment->update({text => 'tag:13.1-0092:important:some_tag', user_id => 99901});
check_tags();

# use version-build format where version doesn't matches
$tag_for_0092_comment->update({text => 'tag:5-0092:important:some_tag', user_id => 99901});
$get = $t->get_ok('/?limit_builds=20&only_tagged=1')->status_is(200);
my @tags = $get->tx->res->dom->find('div.children-collapsed h4 span i.tag')->map('text')->each;
is_deeply(\@tags, [], 'tag is not shown on parent-level because version does not match');
@h4 = $get->tx->res->dom->find("div.children-collapsed h4 a")->map('text')->each;
is_deeply(\@h4, [], 'also no tagged builds on parent-level shown');

# now tag build 0091 to check build tagging when there are common builds
$tag_for_0092_comment->delete();
my $tag_for_0091_comment
  = $opensuse_test_group->comments->create({text => 'tag:0091:important:some_tag', user_id => 99901});

$get = $t->get_ok('/?limit_builds=20&only_tagged=1')->status_is(200);
@h4  = $get->tx->res->dom->find("div.children-collapsed h4 a")->map('text')->each;
is_deeply(\@h4, ['Build0091'], 'only tagged builds on parent-level shown (common build)');
@h4 = $get->tx->res->dom->find('div#group' . $test_parent->id . '_build13_1-0091 h4 a')->map('text')->each;
is_deeply(\@h4, ['opensuse', 'opensuse test'], 'both groups shown, though');

# temporarily create failed job with build 0048@0815 in opensuse test to verify that review badge is only shown
# if all combined builds are reviewed
my $job_hash = {
    BUILD    => '0048@0815',
    DISTRI   => 'opensuse',
    VERSION  => 'Factory',
    FLAVOR   => 'tape',
    ARCH     => 'x86_64',
    MACHINE  => 'xxx',
    TEST     => 'dummy',
    state    => OpenQA::Schema::Result::Jobs::DONE,
    result   => OpenQA::Schema::Result::Jobs::FAILED,
    group_id => $opensuse_test_group->id
};
my $not_reviewed_job = $jobs->create($job_hash);
$t->app->db->resultset('JobModules')->create(
    {
        script   => 'tests/x11/failing_module.pm',
        job_id   => $not_reviewed_job->id,
        category => 'x11',
        name     => 'failing_module',
        result   => 'failed'
    });

my $review_build_id = '-Factory-0048_0815';
$get = $t->get_ok('/?limit_builds=20')->status_is(200);
$t->element_count_is('#review-' . $test_parent->id . $review_build_id,
    0, 'review badge NOT shown for build 0048@0815 anymore');
$t->element_count_is('#child-review-' . $test_parent->id . $review_build_id,
    1, 'review badge review badge for build 0048@0815 still shown on child-level');

$not_reviewed_job->delete();

# auto badges when all passed or all either passed or softfailed
sub check_auto_badge {
    my ($all_passed_count, $build) = @_;
    $build //= '13_1-0092';
    $t->element_count_is('#badge-all-passed-' . $test_parent->id . '-' . $build,
        $all_passed_count, "all passed review badge shown for build $build on parent level");
    $t->element_count_is('#child-badge-all-passed-' . $test_parent->id . '-' . $build,
        $all_passed_count, "all passed review badge shown for build $build on child-level");
}
# all passed
$get = $t->get_ok('/?limit_builds=20')->status_is(200);
check_auto_badge(1);
# all passed or softfailed
$jobs->find({id => 99947})->update({result => OpenQA::Schema::Result::Jobs::SOFTFAILED});
$get = $t->get_ok('/?limit_builds=20')->status_is(200);
check_auto_badge(1);
$jobs->find({id => 99947})->update({result => OpenQA::Schema::Result::Jobs::PASSED});

sub check_badge {
    my ($reviewed_count, $msg, $build) = @_;
    $build //= 'Factory-0048';
    $get = $t->get_ok('/?limit_builds=20')->status_is(200);
    $t->element_count_is('#review-' . $test_parent->id . '-' . $build,       $reviewed_count, $msg . ' (parent-level)');
    $t->element_count_is('#child-review-' . $test_parent->id . '-' . $build, $reviewed_count, $msg . ' (child-level)');
}

# make one of the softfailed jobs a failed because of failed not-important modules
$t->app->db->resultset('JobModules')->create(
    {
        script   => 'tests/x11/failing_module.pm',
        job_id   => 99936,
        category => 'x11',
        name     => 'failing_module',
        result   => 'failed'
    });

# failed:                             not reviewed
# softfailed:                         not reviewed
check_badge(0, 'no badge for completely unreviewed build');

my $softfailed_issueref
  = $opensuse_group->jobs->find({id => 99939})->comments->create({text => 'poo#4322', user_id => 99901});

# failed:                             not reviewed
# softfailed:                         reviewed
check_badge(0, 'no badge as long as not all failed reviewed');

my $failed_not_important_module_issueref
  = $opensuse_group->jobs->find({id => 99936})->comments->create({text => 'poo#4322', user_id => 99901});

# failed:                             not reviewed
# softfailed:                         reviewed
check_badge(0, 'no badge as long as not all failed reviewed');

# add review for job 99938 (so now the other failed jobs are reviewed but one is missing)
my $failed_issueref
  = $opensuse_group->jobs->find({id => 99938})->comments->create({text => 'poo#4321', user_id => 99901});

# failed:                             reviewed
# softfailed:                         reviewed
check_badge(1, 'badge when all failed reviewed, reviewed softfailed with failing module makes no difference');

my $failed_with_non_important_module_issueref
  = $opensuse_group->jobs->find({id => 99936})->comments->create({text => 'poo#4322', user_id => 99901});

# failed:                             reviewed
# softfailed without failing modules: reviewed
check_badge(1, 'badge when all failed reviewed, reviewed softfailed without failing modules makes no difference');

$softfailed_issueref->delete;

# failed:                             reviewed
# softfailed without failing modules: not reviewed
check_badge(1, 'badge when all failed reviewed, unreviewed softfailed without failing modules makes no difference');

$failed_with_non_important_module_issueref->delete;

# failed:                             reviewed
# softfailed without failing modules: not reviewed
check_badge(1, 'badge when all failed reviewed, unreviewed softfailed without failing modules makes no difference');

$opensuse_group->jobs->find({id => 99938})->delete;

# failed:                             deleted
# softfailed without failing modules: not reviewed
check_badge(0, 'no badge when no failed');

$failed_with_non_important_module_issueref
  = $opensuse_group->jobs->find({id => 99936})->comments->create({text => 'poo#4322', user_id => 99901});

# failed:                             deleted
# softfailed without failing modules: not reviewed
check_badge(0, 'no badge when no failed, reviewed softfailed with failing modules makes no difference');

# change DISTRI/VERSION of test in opensuse group to test whether links are still correct then
$opensuse_group->jobs->update({VERSION => '14.2', DISTRI => 'suse'});

$get  = $t->get_ok('/?limit_builds=20&show_tags=0')->status_is(200);
@urls = $get->tx->res->dom->find('h4 a')->each;
is(scalar @urls, 12, 'now builds belong to different versions and are split');
is(
    $urls[1]->attr('href'),
    '/tests/overview?distri=suse&version=14.2&build=87.5011&groupid=1001',
    'most recent version/build'
);
is(
    $urls[-1]->attr('href'),
    '/tests/overview?distri=opensuse&version=13.1&build=0091&groupid=1002',
    'oldest version/build still shown'
);

# helper sub used by next two subtests
sub check_builds {
    my ($build_names, $group, $msg) = @_;
    $get = $t->get_ok('/group_overview/' . $group->id . '?limit_builds=100')->status_is(200);
    my @h4 = $get->tx->res->dom->find("div.no-children h4 a")->map('text')->each;
    is_deeply(\@h4, $build_names, $msg) || diag explain @h4;
}

subtest 'proper build sorting for dotted build number' => sub {
    my $group = $job_groups->create({name => 'dotted version group'});
    $job_hash->{group_id} = $group->id;
    $job_hash->{VERSION}  = '42.1';
    my @builds = qw(
      CURRENT
      :TW.1181 :TW.1180 :TW.1179
      :126416.perl-DBD-mysql.3690 :126006.gnome-control-center.3662 :125970.yast2.2588
      20170112-2 20170112-1 20170111-2
      62.51 62.50 62.49 62.5
      0207
      0185 0184 0183
      0049@0207 0048@0206 0048@0205
    );
    for my $build (@builds) {
        $job_hash->{BUILD} = $build;
        $jobs->create($job_hash);
    }

    # with version sorting, builds should be sorted in order shown
    my @build_names = map { 'Build' . $_ } @builds;
    check_builds(\@build_names, $group, 'builds shown sorted by dotted number');

    # without version sorting, builds should be sorted in reverse order
    # (as the build which most recently had a job created sorts first)
    $group->update({build_version_sort => 0});
    @build_names = reverse @build_names;
    check_builds(\@build_names, $group, 'builds shown sorted by dotted number');
};

subtest 'job groups with multiple version and builds' => sub {
    my $group = $job_groups->create({name => 'multi version group'});
    $job_hash->{group_id} = $group->id;
    sub create_job_version_build {
        my ($version, $build) = @_;
        $job_hash->{VERSION} = $version;
        $job_hash->{BUILD}   = $build;
        $jobs->create($job_hash);
    }

    # create some test builds with jobs
    create_job_version_build('42.3', '0002');
    create_job_version_build('42.3', '0001');
    create_job_version_build('42.2', '2192');
    create_job_version_build('42.2', '2191');
    create_job_version_build('42.2', '0002');

    # with version sorting, builds should be sorted in order shown
    my @build_names = map { 'Build' . $_ } qw(0002 0001 2192 2191 0002);
    check_builds(\@build_names, $group, 'builds shown sorted by dotted versions');

    # without version sorting, builds should be sorted in reverse order
    # (as the build which most recently had a job created sorts first)
    $group->update({build_version_sort => 0});
    @build_names = reverse @build_names;
    check_builds(\@build_names, $group, 'builds shown sorted by job creation time');
};

done_testing;
