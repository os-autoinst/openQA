# Copyright (C) 2014 SUSE Linux Products GmbH
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

package OpenQA::Build;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler;

# This tool is specific to openSUSE
# to enable the Release Team to see the quality at a glance

sub show {
    my $self  = shift;
    my $build = $self->param('buildid');

    if ( $build !~ /[\d.]+$/ ) {
        return $self->render( text => "invalid build", status => 403 );
    }

    $self->app->log->debug("build $build");

    my @configs = ();
    my %archs   = ();
    my %results = ();

    for my $job ( @{ Scheduler::list_jobs( 'build' => $build, fulldetails => 1 ) || [] } ) {
        my $testname = $job->{settings}->{'NAME'};
        my $test     = $job->{test};
        my $flavor   = $job->{settings}->{FLAVOR} || 'sweet';
        my $arch     = $job->{settings}->{ARCH}   || 'noarch';

        my $result;
        if ( $job->{state} eq 'done' ) {
            my $r            = test_result($testname);
            my $result_stats = test_result_stats($r);
            my $overall      = "fail";
            if ( ( $r->{overall} || '' ) eq "ok" ) {
                $overall = ( $r->{dents} ) ? "unknown" : "ok";
            }
            $result = {
                ok      => $result_stats->{ok}   || 0,
                unknown => $result_stats->{unk}  || 0,
                fail    => $result_stats->{fail} || 0,
                overall => $overall,
                jobid   => $job->{id},
                state   => "done",
                testname => $testname,
            };
        }
        elsif ( $job->{state} eq 'running' ) {
            $result = {
                state    => "running",
                testname => $testname,
                jobid    => $job->{id},
            };
        }
        else {
            $result = {
                state    => $job->{state},
                testname => $testname,
                jobid    => $job->{id},
                priority => $job->{priority},
            };
        }

        # Populate @configs and %archs
        push( @configs, $test ) unless ( $test ~~ @configs ); # manage xxx.0, xxx.1 (we only want the most recent one)
        $archs{$flavor} = [] unless $archs{$flavor};
        push( @{ $archs{$flavor} }, $arch ) unless ( $arch ~~ @{ $archs{$flavor} } );

        # Populate %results
        $results{$test} = {} unless $results{$test};
        $results{$test}{$flavor} = {} unless $results{$test}{$flavor};
        $results{$test}{$flavor}{$arch} = $result;
    }

    # Sorting everything
    my @types = keys %archs;
    @types   = sort @types;
    @configs = sort @configs;
    for my $flavor (@types) {
        my @sorted = sort( @{ $archs{$flavor} } );
        $archs{$flavor} = \@sorted;
    }

    $self->stash(
        build   => $build,
        configs => \@configs,
        types   => \@types,
        archs   => \%archs,
        results => \%results,
    );
}

1;
# Local Variables:
# mode: cperl
# cperl-close-paren-offset: -4
# cperl-continued-statement-offset: 4
# cperl-indent-level: 4
# cperl-indent-parens-as-block: t
# cperl-tab-always-indent: t
# indent-tabs-mode: nil
# End:
# vim: set ts=4 sw=4 sts=4 et:
