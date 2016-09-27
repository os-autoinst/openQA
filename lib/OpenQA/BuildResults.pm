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

package OpenQA::BuildResults;
use strict;
use OpenQA::Schema::Result::Jobs;
use Date::Format;

sub compute_build_results {
    my ($app, $group, $limit, $time_limit_days) = @_;

    my $timecond = {">" => time2str('%Y-%m-%d %H:%M:%S', time - 24 * 3600 * $time_limit_days, 'UTC')};

    my %builds;
    my $jobs = $group->jobs->search({"me.t_created" => $timecond});
    my $builds = $jobs->search(
        {},
        {
            select => ['BUILD', {min => 't_created', -as => 'first_hit'}],
            as     => [qw/BUILD first_hit/],
            order_by => {-desc => 'first_hit'},
            group_by => [qw/BUILD/]});
    my $max_jobs = 0;
    my $buildnr  = 0;
    for my $b (map { $_->BUILD } $builds->all) {
        my $jobs = $group->result_source->schema->resultset('Jobs')->search(
            {
                'me.BUILD'    => $b,
                'me.group_id' => $group->id,
                'me.clone_id' => undef,
            },
            {order_by => 'me.id DESC'});
        my %jr = (oldest => DateTime->now, passed => 0, failed => 0, unfinished => 0, labeled => 0, softfailed => 0);

        my $count = 0;
        my %seen;
        my @ids = map { $_->id } $jobs->all;
        # prefetch comments to count. Any comment is considered a label here
        # so a build is considered as 'reviewed' if all failures have at least
        # a comment. This could be improved to distinguish between
        # "only-labels", "mixed" and such
        my $c = $group->result_source->schema->resultset("Comments")->search({job_id => {in => \@ids}});
        my %labels;
        while (my $comment = $c->next) {
            $labels{$comment->job_id}++;
        }
        $jobs->reset;

        while (my $job = $jobs->next) {
            $jr{distri}  //= $job->DISTRI;
            $jr{version} //= $job->VERSION;
            my $key = $job->TEST . "-" . $job->ARCH . "-" . $job->FLAVOR . "-" . $job->MACHINE;
            next if $seen{$key}++;

            $count++;
            $jr{oldest} = $job->t_created if $job->t_created < $jr{oldest};
            if ($job->state eq OpenQA::Schema::Result::Jobs::DONE) {
                if ($job->result eq OpenQA::Schema::Result::Jobs::PASSED) {
                    $jr{passed}++;
                    next;
                }
                if ($job->result eq OpenQA::Schema::Result::Jobs::SOFTFAILED) {
                    $jr{softfailed}++;
                    next;
                }

                if (   $job->result eq OpenQA::Schema::Result::Jobs::FAILED
                    || $job->result eq OpenQA::Schema::Result::Jobs::INCOMPLETE)
                {
                    $jr{failed}++;
                    $jr{labeled}++ if $labels{$job->id};
                    next;
                }
                if (grep { $job->result eq $_ } OpenQA::Schema::Result::Jobs::INCOMPLETE_RESULTS) {
                    next;    # ignore the rest
                }
            }
            if (   $job->state eq OpenQA::Schema::Result::Jobs::CANCELLED
                || $job->state eq OpenQA::Schema::Result::Jobs::OBSOLETED)
            {
                next;        # ignore
            }
            my $state = $job->state;
            if (grep { /$state/ } (OpenQA::Schema::Result::Jobs::PENDING_STATES)) {
                $jr{unfinished}++;
                next;
            }
            $app->log->error("MISSING S:" . $job->state . " R:" . $job->result);
        }
        $jr{reviewed_all_passed} = $jr{passed} == $count;
        $jr{reviewed}            = $jr{failed} > 0 && $jr{labeled} == $jr{failed};
        $builds{$b}              = \%jr;
        $max_jobs = $count if ($count > $max_jobs);
        last if (++$buildnr >= $limit);
    }
    $builds{_max} = $max_jobs if %builds;
    $builds{_group} = $group;

    return \%builds;
}

1;

# vim: set sw=4 et:
