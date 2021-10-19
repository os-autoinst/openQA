# Copyright 2016-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Date::Format qw(time2str);
use Time::Seconds;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '18';
use OpenQA::Test::Utils 'perform_minion_jobs';
use OpenQA::JobGroupDefaults;
use OpenQA::Schema::Result::JobGroupParents;
use OpenQA::Jobs::Constants;

=head2 acceptance criteria

=item tagged builds have a special mark making them distinguishable from other builds (e.g. a star icon)

=cut

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 04-products.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $auth = {'X-CSRF-Token' => $t->ua->get('/tests')->res->dom->at('meta[name=csrf-token]')->attr('content')};
$test_case->login($t, 'percival');

my $schema = $t->app->schema;
my $jobs = $schema->resultset('Jobs');
my $job_groups = $schema->resultset('JobGroups');
my $parent_groups = $schema->resultset('JobGroupParents');
my $comments = $schema->resultset('Comments');

sub post_comment_1001 {
    my ($comment) = @_;
    return $comments->create({group_id => 1001, user_id => 1, text => $comment});
}

sub post_parent_group_comment {
    my ($parent_group_id, $comment) = @_;
    return $comments->create(
        {
            parent_group_id => $parent_group_id,
            user_id => 1,
            text => $comment
        });
}

# this and 'create_job_version_build' are for adding jobs on the fly,
# copied from 22-dashboard.t
my $job_hash = {
    BUILD => '0048@0815',
    DISTRI => 'opensuse',
    VERSION => 'Factory',
    FLAVOR => 'tape',
    ARCH => 'x86_64',
    MACHINE => 'xxx',
    TEST => 'dummy',
    state => OpenQA::Jobs::Constants::DONE,
    result => OpenQA::Jobs::Constants::FAILED,
    group_id => 1001
};

sub create_job_version_build {
    my ($version, $build) = @_;
    my %job_hash;
    $job_hash->{VERSION} = $version;
    $job_hash->{BUILD} = $build;
    $jobs->create($job_hash);
}

=pod
Given 'group_overview' page
When user creates comment with tag:<build_ref>:important:<tag_ref>
Then on page 'group_overview' rendering icon is shown on important builds
=cut
subtest 'tag icon on group overview on important build' => sub {
    my $tag = 'tag:0048:important:GM';
    my $unrelated_comment = 'something_else';
    for my $comment ($tag, $unrelated_comment) {
        post_comment_1001 $comment;
    }
    $t->get_ok('/group_overview/1001')->status_is(200);
    my @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 1, 'one build tagged');
    is($tags[0], 'GM', 'tag description shown');
};

subtest 'test whether tags with @ work, too' => sub {
    post_comment_1001 'tag:0048@0815:important:RC2';
    $t->get_ok('/group_overview/1001')->status_is(200);
    my @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 2, 'two builds tagged');
    # this build will sort *above* the first build, so item 0
    is($tags[0], 'RC2', 'tag description shown');
};

=pod
Given a comment C<tag:<build_ref>:important> exists on a job group comments
When user creates another comment with C<tag:<build_ref>:-important>
Then on page 'group_overview' build C<<build_ref>> is not shown as important
=cut
subtest 'mark build as non-important build' => sub {
    post_comment_1001 'tag:0048@0815:-important';
    $t->get_ok('/group_overview/1001')->status_is(200);
    my @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 1, 'only first build tagged');
};

subtest 'tag on non-existent build does not show up' => sub {
    post_comment_1001 'tag:0066:important';
    $t->get_ok('/group_overview/1001')->status_is(200);
    my @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 1, 'only first build tagged');
};

subtest 'builds first tagged important, then unimportant disappear (poo#12028)' => sub {
    post_comment_1001 'tag:0091:important';
    post_comment_1001 'tag:0091:-important';
    $t->get_ok('/group_overview/1001?limit_builds=1')->status_is(200);
    my @tags = $t->tx->res->dom->find('a[href^=/tests/]')->map('text')->each;
    is(scalar @tags, 2, 'only one build');
    is($tags[0], 'Build87.5011', 'only newest build present');
};

subtest 'only_tagged=1 query parameter shows only tagged (poo#11052)' => sub {
    $t->get_ok('/group_overview/1001?only_tagged=1')->status_is(200);
    is(scalar @{$t->tx->res->dom->find('a[href^=/tests/]')}, 3, 'only one tagged build is shown (on group overview)');
    $t->get_ok('/group_overview/1001?only_tagged=0')->status_is(200);
    is(scalar @{$t->tx->res->dom->find('a[href^=/tests/]')}, 13, 'all builds shown again (on group overview)');

    $t->get_ok('/dashboard_build_results?only_tagged=1')->status_is(200);
    is(scalar @{$t->tx->res->dom->find('a[href^=/tests/]')}, 3, 'only one tagged build is shown (on index page)');
    is(scalar @{$t->tx->res->dom->find('h2')}, 1, 'only one group shown anymore');
    $t->get_ok('/dashboard_build_results?only_tagged=0')->status_is(200);
    is(scalar @{$t->tx->res->dom->find('a[href^=/tests/]')}, 9, 'all builds shown again (on index page)');
    is(scalar @{$t->tx->res->dom->find('h2')}, 2, 'two groups shown again');
};

subtest 'show_tags query parameter enables/disables tags on index page' => sub {
    for my $enabled (0, 1) {
        $t->get_ok('/dashboard_build_results?show_tags=' . $enabled)->status_is(200);
        is(scalar @{$t->tx->res->dom->find('a[href^=/tests/]')},
            9, "all builds shown on index page (show_tags=$enabled)");
        is(scalar @{$t->tx->res->dom->find("i[title='important']")},
            $enabled, "tag (not) shown on index page (show_tags=$enabled)");
    }
};

subtest 'test tags for Fedora compose-style BUILD values' => sub {
    create_job_version_build('26', 'Fedora-26-20170329.n.0');
    post_comment_1001 'tag:Fedora-26-20170329.n.0:important:candidate';
    $t->get_ok('/group_overview/1001')->status_is(200);
    my @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 2, 'two builds tagged');
    # this build will sort *after* the remaining SUSE build, so item 1
    is($tags[1], 'candidate', 'tag description shown');
};

subtest 'test tags for Fedora update-style BUILD values' => sub {
    create_job_version_build('26', 'FEDORA-2017-3456ba4c93');
    post_comment_1001 'tag:FEDORA-2017-3456ba4c93:important:critpath';
    $t->get_ok('/group_overview/1001')->status_is(200);
    my @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 3, 'three builds tagged');
    # this build will sort *before* the other Fedora build, so item 1
    is($tags[1], 'critpath', 'tag description shown');
};

sub query_important_builds {
    my %important_builds_by_group = (0 => $job_groups->new({})->important_builds);
    my $job_groups = $schema->resultset('JobGroups');
    while (my $job_group = $job_groups->next) {
        $important_builds_by_group{$job_group->id} = $job_group->important_builds;
    }
    return \%important_builds_by_group;
}

subtest 'tagging builds via parent group comments' => sub {
    my %expected_important_builds = (
        0 => [],
        1001 => [qw(0048 0066 20170329.n.0 3456ba4c93)],
        1002 => [],
    );

    # create a parent group and move all job groups into it
    my $parent_group = $parent_groups->create({name => 'Test parent', sort_order => 0});
    my $parent_group_id = $parent_group->id;
    while (my $job_group = $job_groups->next) {
        $job_group->update(
            {
                parent_id => $parent_group->id
            });
    }

    # create job with DISTRI=Arch, VERSION=2018 and BUILD=08
    create_job_version_build('1', 'Arch-2018-08');

    # check whether the build is not considered important yet
    my $important_builds = query_important_builds;
    is_deeply($important_builds, \%expected_important_builds, 'build initially not considered important')
      or diag explain $important_builds;

    # create a tag for the job via parent group comments to mark it as important
    post_parent_group_comment($parent_group_id => 'tag:Arch-2018-08:important:fromparent');

    # check whether the tag is visible on both - parent- and child-level
    $t->get_ok('/group_overview/1001')->status_is(200);
    my @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 4, 'four builds tagged');
    is($tags[-1], 'fromparent', 'tag from parent visible on child-level');
    $t->get_ok('/parent_group_overview/' . $parent_group_id)->status_is(200);
    @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 4, 'four builds tagged');
    is($tags[-1], 'fromparent', 'tag from parent visible on parent-level');
    @tags = $t->tx->res->dom->find('.tag-byGroup')->map('text')->each;
    is(scalar @tags, 4, 'four builds tagged');

    # check whether the build is considered important now
    $expected_important_builds{1001} = [qw(0048 0066 08 20170329.n.0 3456ba4c93)];
    $expected_important_builds{1002} = [qw(08)];
    $important_builds = query_important_builds;
    is_deeply($important_builds, \%expected_important_builds, 'tag on parent level marks build as important')
      or diag explain $important_builds;

    # create a tag for the same build on child level
    post_comment_1001('tag:Arch-2018-08:important:fromchild');

    # check whether the tag on child-level could override the previous tag on parent-level
    $t->get_ok('/group_overview/1001')->status_is(200);
    @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 4, 'still four builds tagged');
    is($tags[-1], 'fromchild', 'overriding tag from parent on child-level visible on child-level');
    $t->get_ok('/parent_group_overview/' . $parent_group_id)->status_is(200);
    @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 4, 'still four builds tagged');
    is($tags[-1], 'fromchild', 'overriding tag from parent on child-level visible on parent-level');
    $t->get_ok('/parent_group_overview/' . $parent_group_id)->status_is(200);
    @tags = $t->tx->res->dom->find('.tag-byGroup')->map('text')->each;
    is(scalar @tags, 4, 'still four builds tagged');

    $important_builds = query_important_builds;
    is_deeply($important_builds, \%expected_important_builds, 'build is still considered important')
      or diag explain $important_builds;
};

sub _map_expired {
    my ($jg, $method) = @_;

    my $jobs = $jg->$method;
    return [map { $_->id } @$jobs];
}

subtest 'expired jobs' => sub {
    my $jg = $t->app->schema->resultset('JobGroups')->find(1001);
    my $m;

    for my $file_type (qw(results logs)) {
        # method name for file type
        $m = 'find_jobs_with_expired_' . $file_type;

        # ensure same defaults present
        $jg->update(
            {
                "keep_${file_type}_in_days" => OpenQA::JobGroupDefaults::KEEP_RESULTS_IN_DAYS,
                "keep_important_${file_type}_in_days" => OpenQA::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS,
            });

        is_deeply($jg->$m, [], 'no jobs with expired ' . $file_type);

        $t->app->schema->resultset('Jobs')->find(99938)
          ->update({t_finished => time2str('%Y-%m-%d %H:%M:%S', time - ONE_DAY * 12, 'UTC')});
        is_deeply($jg->$m, [], 'still no jobs with expired ' . $file_type);
        $jg->update({"keep_${file_type}_in_days" => 5});
        # now the unimportant jobs are expired
        is_deeply(_map_expired($jg, $m), [qw(99937 99981)], '2 jobs with expired ' . $file_type);

        $jg->update({"keep_important_${file_type}_in_days" => 15});
        is_deeply(_map_expired($jg, $m), [qw(99937 99981)], 'still 2 jobs with expired ' . $file_type);

        $jg->update({"keep_important_${file_type}_in_days" => 10});
        is_deeply(_map_expired($jg, $m),
            [qw(99937 99938 99981)], 'now also important job 99938 with expired ' . $file_type);
    }

    $t->app->schema->resultset('Jobs')->find(99938)->update({logs_present => 0});
    is_deeply(_map_expired($jg, $m),
        [qw(99937 99981)], 'job with deleted logs not return among jobs with expired logs');
};

=pod
Given a comment C<tag:<build_ref>:important> exists on a job group comments
When GRU cleanup task is run
And job OR job_group OR asset linked to build which is marked as important by comment as above
Then "important builds" are skipped from cleanup
=cut
subtest 'no cleanup of important builds' => sub {
    # build 0048 has already been tagged as important before
    my $job = $jobs->search({id => 99938, state => 'done', group_id => 1001, BUILD => '0048'})->first;
    my $filename = $job->result_dir . '/autoinst-log.txt';
    $job->update({t_finished => time2str('%Y-%m-%d %H:%M:%S', time - ONE_DAY * 12, 'UTC')});
    $job->group->update(
        {
            keep_logs_in_days => 10,
            keep_important_logs_in_days => 100,
            keep_results_in_days => 10,
            keep_important_results_in_days => 100,
        });

    open my $fh, ">>$filename" or die "touch $filename: $!\n";
    close $fh;

    $t->app->gru->enqueue('limit_results_and_logs');
    perform_minion_jobs($t->app->minion);
    ok(-e $filename, 'file still exists');
};

subtest 'version tagging' => sub {
    $t = Test::Mojo->new('OpenQA::WebAPI');

    # alter jobs to have 2 jobs with the same build but different versions in opensuse group
    $jobs->find(99940)->update({VERSION => '1.2-2', BUILD => '5000'});
    $jobs->find(99938)->update({VERSION => '1.2-1', BUILD => '5000'});

    $t->get_ok('/group_overview/1001')->status_is(200);
    $t->element_exists_not('#tag-1001-1_2_2-5000', 'version 1.2-2 not tagged so far');
    $t->element_exists_not('#tag-1001-1_2_1-5000', 'version 1.2-1 not tagged so far');

    post_comment_1001('tag:5000:important:fallback');
    $t->get_ok('/group_overview/1001')->status_is(200);
    $t->text_is('#tag-1001-1_2_2-5000 i', 'fallback', 'version 1.2-2 has fallback tag');
    $t->text_is('#tag-1001-1_2_1-5000 i', 'fallback', 'version 1.2-1 has fallback tag');

    post_comment_1001('tag:1.2-2-5000:important:second');
    $t->get_ok('/group_overview/1001')->status_is(200);
    $t->text_is('#tag-1001-1_2_2-5000 i', 'second', 'version 1.2-2 has version-specific tag');
    $t->text_is('#tag-1001-1_2_1-5000 i', 'fallback', 'version 1.2-1 has still fallback tag');

    post_comment_1001('tag:1.2-1-5000:important:first');
    $t->get_ok('/group_overview/1001')->status_is(200);
    $t->text_is('#tag-1001-1_2_2-5000 i', 'second', 'version 1.2-2 has version-specific tag');
    $t->text_is('#tag-1001-1_2_1-5000 i', 'first', 'version 1.2-1 has version-specific tag');
};

subtest 'content negotiation' => sub {
    $t->get_ok('/group_overview/1001')->status_is(200)->content_type_is('text/html;charset=UTF-8');
    $t->get_ok('/group_overview/1001.html')->status_is(200)->content_type_is('text/html;charset=UTF-8');
    $t->get_ok('/group_overview/1001' => {Accept => 'text/html'})->status_is(200)
      ->content_type_is('text/html;charset=UTF-8');
    $t->get_ok('/group_overview/1001.json')->status_is(200)->content_type_is('application/json;charset=UTF-8');
    $t->get_ok('/group_overview/1001' => {Accept => 'application/json'})->status_is(200)
      ->content_type_is('application/json;charset=UTF-8');
};

done_testing;
