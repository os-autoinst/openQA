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
use Date::Format qw(time2str);

my $test_case;
my $t;
my $auth;

=head2 acceptance criteria

=item tagged builds have a special mark making them distinguishable from other builds (e.g. a star icon)

=cut

sub set_up {
    $test_case = OpenQA::Test::Case->new;
    $test_case->init_data;
    $t = Test::Mojo->new('OpenQA::WebAPI');
    $auth = {'X-CSRF-Token' => $t->ua->get('/tests')->res->dom->at('meta[name=csrf-token]')->attr('content')};
    $test_case->login($t, 'percival');
}

sub post_comment_1001 {
    my ($comment) = @_;
    $t->post_ok('/api/v1/groups/1001/comments', $auth => form => {text => $comment})->status_is(200);
}

set_up;

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
    is(scalar @tags, 1,           'only one build');
    is($tags[0],     'Build0092', 'only youngest build present');
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
        is(scalar @{$t->tx->res->dom->find('a[href^=/tests/]')},     4,        "all builds shown on index page (show_tags=$enabled)");
        is(scalar @{$t->tx->res->dom->find("i[title='important']")}, $enabled, "tag (not) shown on index page (show_tags=$enabled)");
    }
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

    my @jobs = $t->app->db->resultset('Jobs')->search({state => 'done', group_id => 1001})->all;
    my @jobs_in_build = grep { $_->settings_hash->{BUILD} eq '0048' } @jobs;
    my $job           = $jobs_in_build[1];
    my %args          = (resultdir => $job->result_dir, jobid => $job->id);
    my $filename      = $job->result_dir . '/autoinst-log.txt';
    open my $fh, ">>$filename" or die "touch $filename: $!\n";
    close $fh;

    post_comment_1001 'tag:0048:important';
    $t->app->gru->enqueue('reduce_result' => \%args);
    $c->run('run', '-o');
    ok(-e $filename, 'file still exists');
};

sub _map_expired {
    my ($jg) = @_;
    my $jobs = $jg->expired_jobs;
    return [map { $_->id } @$jobs];
}

subtest 'expired_jobs' => sub {
    my $jg = $t->app->db->resultset('JobGroups')->find(1001);
    is_deeply($jg->expired_jobs, [], 'no jobs expired');
    $t->app->db->resultset('Jobs')->find(99938)->update({t_finished => time2str('%Y-%m-%d %H:%M:%S', time - 3600 * 24 * 12, 'UTC')});
    is_deeply($jg->expired_jobs, [], 'still no jobs expired');
    $jg->update({keep_results_in_days => 5});
    # now the unimportant jobs are expired
    is_deeply(_map_expired($jg), [qw(99937 99981)], '2 jobs expired');
    $jg->update({keep_important_results_in_days => 15});
    is_deeply(_map_expired($jg), [qw(99937 99981)], 'still 2 jobs expired');
    $jg->update({keep_important_results_in_days => 10});
    is_deeply(_map_expired($jg), [qw(99937 99938 99981)], 'now important 99938 expired too');
};

done_testing;
