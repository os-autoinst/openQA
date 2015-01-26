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

package OpenQA::Controller::Test;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::Scheduler qw/worker_get/;
use File::Basename;
use POSIX qw/strftime/;
use Data::Dumper;

sub list {
    my $self = shift;

    my $match;
    if(defined($self->param('match'))) {
        $match = $self->param('match');
        $match =~ s/[^\w\[\]\{\}\(\),:.+*?\\\$^|-]//g; # sanitize
    }

    my $hoursfresh = $self->param('hoursfresh');
    $hoursfresh = 4*24 unless defined($hoursfresh);
    $self->param(hoursfresh => $hoursfresh);
    my $limit = $self->param('limit');
    my $page = $self->param('page');
    my $scope = $self->param('scope');
    $scope = 'relevant' unless defined($scope);
    $self->param(scope => $scope);
    my $state = $self->param('state') // 'scheduled,running,waiting,done';
    $state = undef if $state eq 'all';

    my $assetid = $self->param('assetid');

    if (defined $limit && $limit =~ m/\D/) {
        $limit = undef;
    }
    if ($page && $page =~ m/\D/) {
        $page = undef;
    }
    if ($limit && $limit > 500) {
        $limit = 500;
    }

    my @slist=();
    my @list=();

    my $jobs = OpenQA::Scheduler::list_jobs(
        state => $state,
        match => $match,
        limit => $limit,
        page => $page,
        ignore_incomplete => $self->param('ignore_incomplete')?1:0,
        maxage => $hoursfresh*3600,
        scope => $scope,
        assetid => $assetid,
    ) || [];

    my $result_stats = Schema::Result::JobModules::job_module_stats($jobs);

    for my $job (@$jobs) {

        if ($job->{state} =~ /^(?:running|waiting|done)$/) {

            my $run_stat = {};
            if ($job->{state} eq 'running') {
                my $testdirname = $job->{'settings'}->{'NAME'};
                my $running_basepath = running_log($testdirname);
                my $results = test_result($testdirname);
                $run_stat = Schema::Result::JobModules::running_modinfo($job);
                $run_stat->{'run_backend'} = 0;
            }

            my $settings = {
                job => $job,

                result_stats => $result_stats->{$job->{id}},
                overall=>$job->{state}||'unk',
                run_stat=>$run_stat
            };
            if ($job->{state} ne 'done') {
                unshift @list, $settings;
            }
            else {
                push @list, $settings;
            }
        }
        else {
            my $settings = {job => $job};

            push @slist, $settings;
        }
    }

    $self->stash(slist => \@slist);
    $self->stash(list => \@list);
    $self->stash(ntest => @list + @slist);
    $self->stash(prj => $prj);
    $self->stash(hoursfresh => $hoursfresh);

}

sub show {
    my $self = shift;

    return $self->reply->not_found if (!defined $self->param('testid'));

    my $job = OpenQA::Scheduler::job_get($self->param('testid'));

    return $self->reply->not_found unless $job;

    my $testdirname = $job->{'settings'}->{'NAME'};
    my $testresultdir = OpenQA::Utils::testresultdir($testdirname);

    return $self->render(text => "Invalid path", status => 403) if ($testdirname=~/(?:\.\.)|[^a-zA-Z0-9._+-:]/);

    $self->stash(testname => $job->{'name'});
    $self->stash(resultdir => $testresultdir);
    $self->stash(assets => OpenQA::Scheduler::job_get_assets($job->{'id'}));

    #  return $self->reply->not_found unless (-e $self->stash('resultdir'));

    # If it's running
    if ($job->{state} =~ /^(?:running|waiting)$/) {
        $self->stash(worker => worker_get($job->{'worker_id'}));
        $self->stash(backend_info => 'TODO'); # $results->{backend});
        $self->stash(job => $job);
        $self->render('test/running');
        return;
    }

    my @modlist=();
    foreach my $module (Schema::Result::JobModules::job_modules($job)) {
        my $name = $module->name();
        # add link to $testresultdir/$name*.png via png CGI
        my @imglist;
        my @wavlist;
        my $num = 1;
        foreach my $img (@{$module->details($testresultdir)}) {
            if( $img->{'screenshot'} ) {
                push(@imglist, {name => $img->{'screenshot'}, num => $num++, result => $img->{'result'}});
            }
            elsif( $img->{'audio'} ) {
                push(@wavlist, {name => $img->{'audio'}, num => $num++, result => $img->{'result'}});
            }
        }

        #FIXME: Read ocr also from results.json as soon as we know how it looks like

        # add link to $testresultdir/$name*.txt as direct link
        my @ocrlist;
        foreach my $ocrpath (<$testresultdir/$name-[0-9]*.txt>) {
            $ocrpath = data_name($ocrpath);
            my $ocrscreenshotid = $ocrpath;
            $ocrscreenshotid=~s/^\w+-(\d+)/$1/;
            my $ocrres = $module->{'screenshots'}->[--$ocrscreenshotid]->{'ocr_result'} || 'na';
            push(@ocrlist, {name => $ocrpath, result => $ocrres});
        }

        push(
            @modlist,
            {
                name => $module->name,
                result => $module->result,
                screenshots => \@imglist,
                wavs => \@wavlist,
                ocrs => \@ocrlist,
                soft_failure => $module->soft_failure,
                milestone => $module->milestone,
                important => $module->important,
                fatal => $module->fatal
            }
        );
    }

    # result files box
    my @resultfiles = test_resultfile_list($testdirname);

    # uploaded logs box
    my @ulogs = test_uploadlog_list($testdirname);

    $self->stash(modlist => \@modlist);
    $self->stash(backend_info => {'backend' => 'TODO' });
    $self->stash(resultfiles => \@resultfiles);
    $self->stash(ulogs => \@ulogs);
    $self->stash(job => $job);

    $self->render('test/result');
}

# Custom action enabling the openSUSE Release Team
# to see the quality at a glance
sub overview {
    my $self  = shift;
    my $validation = $self->validation;

    $validation->required('distri');
    $validation->required('version');
    if ($validation->has_error) {
        return $self->render(text => 'Missing parameters', status => 404);
    }
    my $distri = $self->param('distri');
    my $version = $self->param('version');

    my %search_args = (distri => $distri, version => $version);

    my $flavor = $self->param('flavor');
    if ($flavor) {
        $search_args{flavor} = $flavor;
    }

    my $build = $self->param('build');
    if (!$build) {
        $build = $self->db->resultset("Jobs")->latest_build(%search_args);
    }

    $search_args{build} = $build;
    $search_args{fulldetails} = 1;
    $search_args{scope} = 'current';

    my @configs = ();
    my %archs   = ();
    my %results = ();
    my $aggregated = {none => 0, passed => 0, failed => 0, incomplete => 0, scheduled => 0, running => 0, unknown => 0};

    my $jobs = OpenQA::Scheduler::list_jobs(%search_args) || [];

    my $all_result_stats = OpenQA::Schema::Result::JobModules::job_module_stats($jobs);

    for my $job (@$jobs) {
        my $testname = $job->{settings}->{'NAME'};
        my $test     = $job->{test};
        my $flavor   = $job->{settings}->{FLAVOR} || 'sweet';
        my $arch     = $job->{settings}->{ARCH}   || 'noarch';

        my $result;
        if ( $job->{state} eq 'done' ) {
            my $result_stats = $all_result_stats->{$job->{id}};
            my $failures     = get_failed_needles($testname);
            my $overall      = $job->{result};
            if ( $job->{result} eq "passed" && $result_stats->{dents}) {
                $overall = "unknown";
            }
            $result = {
                passed  => $result_stats->{passed},
                unknown => $result_stats->{unk},
                failed  => $result_stats->{failed},
                dents   => $result_stats->{dents},
                overall => $overall,
                jobid   => $job->{id},
                state   => "done",
                testname => $testname,
                failures => $failures,
            };
            $aggregated->{$overall}++;
        }
        elsif ( $job->{state} eq 'running' ) {
            $result = {
                state    => "running",
                testname => $testname,
                jobid    => $job->{id},
            };
            $aggregated->{'running'}++;
        }
        else {
            $result = {
                state    => $job->{state},
                testname => $testname,
                jobid    => $job->{id},
                priority => $job->{priority},
            };
            if ( $job->{state} eq 'scheduled' ) {
                $aggregated->{'scheduled'}++;
            }
            else {
                $aggregated->{'none'}++;
            }
        }

        # Populate @configs and %archs
        $test = $test.'@'.$job->{settings}->{MACHINE} unless ( $job->{settings}->{MACHINE} eq '64bit' || $job->{settings}->{MACHINE} eq '32bit' );
        push( @configs, $test ) unless ( grep { $test eq $_ } @configs );
        $archs{$flavor} = [] unless $archs{$flavor};
        push( @{ $archs{$flavor} }, $arch ) unless ( grep { $arch eq $_ } @{ $archs{$flavor} } );

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
        version => $version,
        distri => $distri,
        configs => \@configs,
        types   => \@types,
        archs   => \%archs,
        results => \%results,
        aggregated => $aggregated
    );
}

sub menu {
    my $self = shift;

    return $self->reply->not_found if (!defined $self->param('testid'));

    my $job = OpenQA::Scheduler::job_get($self->param('testid'));

    $self->stash(state => $job->{'state'});
    $self->stash(prio => $job->{'priority'});
    $self->stash(jobid => $job->{'id'});
}

1;
# vim: set sw=4 et:
