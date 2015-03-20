# Copyright (C) 2015 SUSE Linux GmbH
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

package OpenQA::Controller::Main;
use strict;
use warnings;
use Mojo::Base 'Mojolicious::Controller';
use Date::Format;
use OpenQA::Schema::Result::Jobs;

sub index {
    my ($self) = @_;

    my @results;

    my $timecond = { ">" => time2str('%Y-%m-%d %H:%M:%S', time-24*3600*14, 'UTC') };
    my $groups = $self->db->resultset('JobGroups')->search({}, { order_by => qw/name/ });
    while (my $group = $groups->next) {
        my %res;
        my $jobs = $group->jobs->search({"me.t_created" =>  $timecond,});
        my $builds = $self->db->resultset('JobSettings')->search(
            {
                job_id => { -in => $jobs->get_column('id')->as_query },
                key => 'BUILD'
            },
            { columns => qw/value/, distinct => 1 }
        );
        my $max_jobs = 0;
        my $buildnr = 0;
        for my $b (sort { $b <=> $a } map { $_->value } $builds->all) {
            my $jobs = $self->db->resultset('Jobs')->search(
                {
                    'settings.key' => 'BUILD',
                    'settings.value' => $b,
                    'me.group_id' => $group->id,
                    'me.clone_id' => undef,
                },
                { join => qw/settings/ }
            );
            my %jr = ( oldest => DateTime->now, passed => 0, failed => 0, inprogress => 0 );

            my $count = 0;
            while (my $job = $jobs->next) {
                $count++;
                $jr{oldest} = $job->t_created if $job->t_created < $jr{oldest};
                if ($job->state eq OpenQA::Schema::Result::Jobs::DONE) {
                    if ($job->result eq OpenQA::Schema::Result::Jobs::PASSED) {
                        $jr{passed}++;
                        next;
                    }
                    if (  $job->result eq OpenQA::Schema::Result::Jobs::FAILED
                        ||$job->result eq OpenQA::Schema::Result::Jobs::INCOMPLETE)
                    {
                        $jr{failed}++;
                        next;
                    }
                    if ( grep { $job->result eq $_ } OpenQA::Schema::Result::Jobs::INCOMPLETE_RESULTS ) {
                        next; # ignore the rest
                    }
                }
                if (  $job->state eq OpenQA::Schema::Result::Jobs::CANCELLED
                    ||$job->state eq OpenQA::Schema::Result::Jobs::OBSOLETED)
                {
                    next; # ignore
                }
                if ( $job->state eq OpenQA::Schema::Result::Jobs::SCHEDULED || $job->state eq OpenQA::Schema::Result::Jobs::RUNNING ) {
                    $jr{inprogress}++;
                    next;
                }
                $self->app->log->error("MISSING S:" . $job->state . " R:" . $job->result);
            }
            $self->app->log->debug($jr{oldest});
            $res{$b} = \%jr;
            $max_jobs = $count if ($count > $max_jobs);
            last if (++$buildnr > 2);
        }
        if (%res) {
            $res{_group} = $group;
            $res{_max} = $max_jobs;
            push(@results, \%res);
        }
    }
    $self->stash('results', \@results);
}

1;
# vim: set sw=4 et:
