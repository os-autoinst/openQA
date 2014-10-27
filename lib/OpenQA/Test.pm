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

package OpenQA::Test;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler qw/worker_get/;
use File::Basename;
use POSIX qw/strftime/;

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

    for my $job (
        @{
            Scheduler::list_jobs(
                state => $state,
                match => $match,
                limit => $limit,
                page => $page,
                ignore_incomplete => $self->param('ignore_incomplete')?1:0,
                maxage => $hoursfresh*3600,
                scope => $scope,
                assetid => $assetid,
              )
              ||[]
        }
      )
    {

        if ($job->{state} =~ /^(?:running|waiting|done)$/) {

            my $testdirname = $job->{'settings'}->{'NAME'};
            my $results = test_result($testdirname);
            my $result_stats = test_result_stats($results);
            my $backend = $results->{'backend'}->{'backend'} || '';
            $backend =~ s/^.*:://;

            my $run_stat;
            if ($job->{state} eq 'running') {
                my $running_basepath = running_log($testdirname);
                $run_stat = get_running_modinfo($results);
                $run_stat->{'run_backend'} = 0;
                if(-e "$running_basepath/os-autoinst.pid") {
                    my $backpid = file_content("$running_basepath/os-autoinst.pid");
                    chomp($backpid);
                    $run_stat->{'run_backend'} = (-e "/proc/$backpid"); # kill 0 does not work with www user
                }
            }

            my $settings = {
                job => $job,

                res_ok=>$result_stats->{ok}||0,
                res_unknown=>$result_stats->{unk}||0,
                res_fail=>$result_stats->{fail}||0,
                res_overall=>$results->{overall},
                res_dents=>$results->{dents},
                run_stat=>$run_stat,
                backend => $backend,
            };
            if ($job->{state} ne 'done') {
                unshift @list, $settings;
            }
            else {
                push @list, $settings;
            }
        }
        else {
            my $settings = {job => $job,};

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

    return $self->render_not_found if (!defined $self->param('testid'));

    my $job = Scheduler::job_get($self->param('testid'));

    my $testdirname = $job->{'settings'}->{'NAME'};
    my $testresultdir = openqa::testresultdir($testdirname);

    return $self->render(text => "Invalid path", status => 403) if ($testdirname=~/(?:\.\.)|[^a-zA-Z0-9._+-:]/);

    $self->stash(testname => $job->{'name'});
    $self->stash(resultdir => $testresultdir);
    $self->stash(assets => Scheduler::job_get_assets($job->{'id'}));

    # FIXME: inherited from the old webUI, should really really really die
    $self->stash(res_css => $res_css);
    $self->stash(res_display => $res_display);

    #  return $self->render_not_found unless (-e $self->stash('resultdir'));

    my $results = test_result($testdirname);

    # If it's running
    if ($job->{state} =~ /^(?:running|waiting)$/) {
        $self->stash(worker => worker_get($job->{'worker_id'}));
        $self->stash(backend_info => $results->{backend});
        $self->stash(job => $job);
        $self->render('test/running');
        return;
    }

    my @modlist=();
    foreach my $module (@{$results->{'testmodules'}}) {
        my $name = $module->{'name'};
        # add link to $testresultdir/$name*.png via png CGI
        my @imglist;
        my @wavlist;
        my $num = 1;
        foreach my $img (@{$module->{'details'}}) {
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
                name => $module->{'name'},
                result => $module->{'result'},
                dents => $module->{'dents'},
                screenshots => \@imglist,
                wavs => \@wavlist,
                ocrs => \@ocrlist,
                flags => $module->{'flags'}
            }
        );
    }

    # TODO: make better
    my $backlogpath = back_log($testdirname);
    my $diskimg = 0;
    if(-e "$backlogpath/l1") {
        if((stat("$backlogpath/l1"))[12] && !((stat("$backlogpath/l2"))[12])) { # skip raid
            $diskimg = 1;
        }
    }

    # result files box
    my @resultfiles = test_resultfile_list($testdirname);

    # uploaded logs box
    my @ulogs = test_uploadlog_list($testdirname);

    $self->stash(overall => $job->{result});
    $self->stash(modlist => \@modlist);
    $self->stash(diskimg => $diskimg);
    $self->stash(backend_info => $results->{backend});
    $self->stash(resultfiles => \@resultfiles);
    $self->stash(ulogs => \@ulogs);
    $self->stash(job => $job);

    $self->render('test/result');
}

sub uploadlog{
    my $self = shift;

    my $job = Scheduler::job_get($self->param('testid'));

    if (!$job) {
        return $self->render(message => 'No such job.', status => 404);
    }

    my $testdirname = $job->{'settings'}->{'NAME'};

    return $self->render(text => "Invalid path", status => 403) if ($testdirname=~/(?:\.\.)|[^a-zA-Z0-9._+-:]/);

    if ($self->req->is_limit_exceeded) {
        return $self->render(
            message => 'File is too big.',
            status => 200
        );
    }

    if ($job->{state} ne 'running') {
        $self->app->log->warn("test $job->{id} is not running, refused to upload logs");
        return $self->render(text => "test not running", status => 400);
    }

    my $upload = $self->req->upload('upload');
    if (!$upload) {
        return $self->render(message => 'upload file content missing', status => 400);
    }

    my $dir = join('/', $openqa::loguploaddir, $testdirname);
    if (!-e $dir) {
        mkdir($dir) or die "$!";
    }
    my $upname = basename($self->param('filename'));
    $upname = sanitize_testname($upname);

    $upload->move_to(join('/', $dir, $upname));

    return $self->render(text => "OK: $upname\n");
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

    for my $job ( @{ Scheduler::list_jobs(%search_args) || [] } ) {
        my $testname = $job->{settings}->{'NAME'};
        my $test     = $job->{test};
        my $flavor   = $job->{settings}->{FLAVOR} || 'sweet';
        my $arch     = $job->{settings}->{ARCH}   || 'noarch';

        my $result;
        if ( $job->{state} eq 'done' ) {
            my $r            = test_result($testname);
            my $result_stats = test_result_stats($r);
            my $failures     = get_failed_needles($testname);
            my $overall      = $job->{result};
            if ( $job->{result} eq "passed" && $r->{dents}) {
                $overall = "unknown";
            }
            $result = {
                ok      => $result_stats->{ok}   || 0,
                unknown => $result_stats->{unk}  || 0,
                fail    => $result_stats->{fail} || 0,
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

    return $self->render_not_found if (!defined $self->param('testid'));

    my $job = Scheduler::job_get($self->param('testid'));

    $self->stash(state => $job->{'state'});
    $self->stash(prio => $job->{'priority'});
    $self->stash(jobid => $job->{'id'});
}

1;
# vim: set sw=4 et:
