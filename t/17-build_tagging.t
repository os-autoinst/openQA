# Copyright (C) 2016 SUSE Linux GmbH
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

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;
use OpenQA::Schema::JobGroupDefaults;
use Date::Format qw(time2str);

=head2 acceptance criteria

=item tagged builds have a special mark making them distinguishable from other builds (e.g. a star icon)

=cut

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $auth = {'X-CSRF-Token' => $t->ua->get('/tests')->res->dom->at('meta[name=csrf-token]')->attr('content')};
$test_case->login($t, 'percival');

my $jobs     = $t->app->db->resultset('Jobs');
my $comments = $t->app->db->resultset('Comments');

sub post_comment_1001 {
    my ($comment) = @_;
    return $comments->create({group_id => 1001, user_id => 99901, text => $comment});
}

=pod
Given 'group_overview' page
When user creates comment with tag:<build_ref>:important:<tag_ref>
Then on page 'group_overview' rendering icon is shown on important builds
=cut
subtest 'tag icon on group overview on important build' => sub {
    my $tag               = 'tag:0048:important:GM';
    my $unrelated_comment = 'something_else';
    for my $comment ($tag, $unrelated_comment) {
        post_comment_1001 $comment;
    }
    my $get  = $t->get_ok('/group_overview/1001')->status_is(200);
    my @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 1,    'one build tagged');
    is($tags[0],     'GM', 'tag description shown');
};

subtest 'test whether tags with @ work, too' => sub {
    post_comment_1001 'tag:0048@0815:important:GM';
    my $get  = $t->get_ok('/group_overview/1001')->status_is(200);
    my @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 2,    'one build tagged');
    is($tags[0],     'GM', 'tag description shown');
};

=pod
Given a comment C<tag:<build_ref>:important> exists on a job group comments
When user creates another comment with C<tag:<build_ref>:-important>
Then on page 'group_overview' build C<<build_ref>> is not shown as important
=cut
subtest 'mark build as non-important build' => sub {
    post_comment_1001 'tag:0048@0815:-important';
    my $get  = $t->get_ok('/group_overview/1001')->status_is(200);
    my @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 1, 'only first build tagged');
};

subtest 'tag on non-existent build does not show up' => sub {
    post_comment_1001 'tag:0066:important';
    my $get  = $t->get_ok('/group_overview/1001')->status_is(200);
    my @tags = $t->tx->res->dom->find('.tag')->map('text')->each;
    is(scalar @tags, 1, 'only first build tagged');
};

subtest 'builds first tagged important, then unimportant dissappear (poo#12028)' => sub {
    post_comment_1001 'tag:0091:important';
    post_comment_1001 'tag:0091:-important';
    my $get  = $t->get_ok('/group_overview/1001?limit_builds=1')->status_is(200);
    my @tags = $t->tx->res->dom->find('a[href^=/tests/]')->map('text')->each;
    is(scalar @tags, 1, 'only one build');
    is($tags[0], 'Build87.5011', 'only newest build present');
};

subtest 'only_tagged=1 query parameter shows only tagged (poo#11052)' => sub {
    my $get = $t->get_ok('/group_overview/1001?only_tagged=1')->status_is(200);
    is(scalar @{$t->tx->res->dom->find('a[href^=/tests/]')}, 1, 'only one tagged build is shown (on group overview)');
    $get = $t->get_ok('/group_overview/1001?only_tagged=0')->status_is(200);
    is(scalar @{$t->tx->res->dom->find('a[href^=/tests/]')}, 5, 'all builds shown again (on group overview)');

    $get = $t->get_ok('/?only_tagged=1')->status_is(200);
    is(scalar @{$t->tx->res->dom->find('a[href^=/tests/]')}, 1, 'only one tagged build is shown (on index page)');
    is(scalar @{$t->tx->res->dom->find('h2')},               1, 'only one group shown anymore');
    $get = $t->get_ok('/?only_tagged=0')->status_is(200);
    is(scalar @{$t->tx->res->dom->find('a[href^=/tests/]')}, 4, 'all builds shown again (on index page)');
    is(scalar @{$t->tx->res->dom->find('h2')},               2, 'two groups shown again');
};

subtest 'show_tags query parameter enables/disables tags on index page' => sub {
    for my $enabled (0, 1) {
        my $get = $t->get_ok('/?show_tags=' . $enabled)->status_is(200);
        is(scalar @{$t->tx->res->dom->find('a[href^=/tests/]')},
            4, "all builds shown on index page (show_tags=$enabled)");
        is(scalar @{$t->tx->res->dom->find("i[title='important']")},
            $enabled, "tag (not) shown on index page (show_tags=$enabled)");
    }
};

sub _map_expired {
    my ($jg, $method) = @_;

    my $jobs = $jg->$method;
    return [map { $_->id } @$jobs];
}

subtest 'expired jobs' => sub {
    my $jg = $t->app->db->resultset('JobGroups')->find(1001);
    my $m;

    for my $file_type (qw(results logs)) {
        # method name for file type
        $m = 'find_jobs_with_expired_' . $file_type;

        # ensure same defaults present
        $jg->update(
            {
                "keep_${file_type}_in_days" => OpenQA::Schema::JobGroupDefaults::KEEP_RESULTS_IN_DAYS,
                "keep_important_${file_type}_in_days" =>
                  OpenQA::Schema::JobGroupDefaults::KEEP_IMPORTANT_RESULTS_IN_DAYS,
            });

        is_deeply($jg->$m, [], 'no jobs with expired ' . $file_type);

        $t->app->db->resultset('Jobs')->find(99938)
          ->update({t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600 * 24 * 12, 'UTC')});
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

    $t->app->db->resultset('Jobs')->find(99938)->update({logs_present => 0});
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
    my $c = OpenQA::WebAPI::Plugin::Gru::Command::gru->new();
    $c->app($t->app);

    # build 0048 has already been tagged as important before
    my @jobs     = $jobs->search({state => 'done', group_id => 1001, BUILD => '0048'})->all;
    my $job      = $jobs[1];
    my $filename = $job->result_dir . '/autoinst-log.txt';
    $job->update({t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600 * 24 * 12, 'UTC')});
    $job->group->update(
        {
            keep_logs_in_days              => 10,
            keep_important_logs_in_days    => 100,
            keep_results_in_days           => 10,
            keep_important_results_in_days => 100,
        });

    open my $fh, ">>$filename" or die "touch $filename: $!\n";
    close $fh;

    $t->app->gru->enqueue('limit_results_and_logs');
    $c->run('run', '-o');
    ok(-e $filename, 'file still exists');
};

subtest 'version tagging' => sub {
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
    $t->text_is('#tag-1001-1_2_2-5000 i', 'second',   'version 1.2-2 has version-specific tag');
    $t->text_is('#tag-1001-1_2_1-5000 i', 'fallback', 'version 1.2-1 has still fallback tag');

    post_comment_1001('tag:1.2-1-5000:important:first');
    $t->get_ok('/group_overview/1001')->status_is(200);
    $t->text_is('#tag-1001-1_2_2-5000 i', 'second', 'version 1.2-2 has version-specific tag');
    $t->text_is('#tag-1001-1_2_1-5000 i', 'first',  'version 1.2-1 has version-specific tag');
};

done_testing;
