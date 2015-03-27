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

package OpenQA::Controller::Test;
use strict;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use File::Basename;
use POSIX qw/strftime/;
use JSON qw/decode_json/;

sub list {
    my $self = shift;

    my $match;
    if(defined($self->param('match'))) {
        $match = $self->param('match');
        $match =~ s/[^\w\[\]\{\}\(\),:.+*?\\\$^|-]//g; # sanitize
    }

    my $scope = $self->param('scope');
    $scope = 'relevant' unless defined($scope);
    $self->param(scope => $scope);

    my $assetid = $self->param('assetid');
    my $groupid = $self->param('groupid');

    my $jobs = OpenQA::Scheduler::query_jobs(
        state => 'done,cancelled',
        match => $match,
        scope => $scope,
        assetid => $assetid,
        groupid => $groupid,
        limit => 500,
        idsonly => 1
    );
    $self->stash(jobs => $jobs);

    my $running = OpenQA::Scheduler::query_jobs(state => 'running,waiting', match => $match, groupid => $groupid, assetid => $assetid);
    my $result_stats = OpenQA::Schema::Result::JobModules::job_module_stats($running);
    my @list;
    while (my $job = $running->next) {
        my $data = {
            job => $job,
            result_stats => $result_stats->{$job->id},
            run_stat => $job->running_modinfo(),
        };
        push @list, $data;
    }
    $self->stash(running => \@list);

    my $scheduled = OpenQA::Scheduler::query_jobs(state => 'scheduled', match => $match, groupid => $groupid, assetid => $assetid);
    $self->stash(scheduled => $scheduled);

}

sub list_ajax {
    my ($self) = @_;
    my $res = {};

    my $jobs;

    my $st = time;
    my $result_stats;
    my @ids;
    # we have to seperate the initial loading and the reload
    if ($self->param('initial')) {
        @ids = map { scalar($_) } @{$self->every_param('jobs[]')};
        $jobs = OpenQA::Scheduler::query_jobs(ids => \@ids);
        $result_stats = OpenQA::Schema::Result::JobModules::job_module_stats(\@ids);
    }
    else {
        my $scope = '';
        $scope = 'relevant' if $self->param('relevant') ne 'false';

        $jobs = OpenQA::Scheduler::query_jobs(
            state => 'done,cancelled',
            scope => $scope,
            limit => 500,
        );
        while (my $j = $jobs->next) { push(@ids, $j->id); }
        $jobs->reset;
        $result_stats = OpenQA::Schema::Result::JobModules::job_module_stats(\@ids);
    }

    my %settings;

    my $query = $self->db->resultset("JobSettings")->search(
        {
            job_id => { in => \@ids },
            key => { in => [qw/DISTRI VERSION ARCH FLAVOR BUILD MACHINE/] }
        }
    );
    while (my $s = $query->next) {
        $settings{$s->job_id}->{$s->key} = $s->value;
    }

    my %deps;

    for my $id (@ids) {
        $deps{$id} = {
            parents => {'Chained' => [], 'Parallel' => []},
            children => {'Chained' => [], 'Parallel' => []}
        };
    }

    $query = $self->db->resultset("JobDependencies")->search([{ child_job_id => { in => \@ids } },{ parent_job_id => { in => \@ids } }]);

    while (my $s = $query->next) {
        push(@{$deps{$s->parent_job_id}->{children}->{$s->to_string}}, $s->child_job_id);
        push(@{$deps{$s->child_job_id}->{parents}->{$s->to_string}}, $s->parent_job_id);
    }

    $jobs = $self->db->resultset("Jobs")->search({ id => { in => \@ids } },{ columns => [qw/id state clone_id test result group_id t_created/], order_by => ['me.id DESC'] });

    my @list;
    while (my $job = $jobs->next) {
        my $data = {
            "DT_RowId" => "job_" .  $job->id,
            id => $job->id,
            result_stats => $result_stats->{$job->id},
            deps => $deps{$job->id},
            clone => $job->clone_id,
            test => $job->test . "@" . $settings{$job->id}->{MACHINE} // '',
            distri => $settings{$job->id}->{DISTRI} // '',
            version => $settings{$job->id}->{VERSION} // '',
            flavor => $settings{$job->id}->{FLAVOR} // '',
            arch => $settings{$job->id}->{ARCH} // '',
            build => $settings{$job->id}->{BUILD} // '',
            testtime => $job->t_created,
            result => $job->result,
            group => $job->group_id,
            state => $job->state
        };
        push @list, $data;
    }

    $self->render(json => {data => \@list});
}

sub test_uploadlog_list($) {
    # get a list of uploaded logs
    my $testresdir = shift;
    my @filelist;
    for my $f (<$testresdir/ulogs/*>) {
        $f=~s#.*/##;
        push(@filelist, $f);
    }
    return @filelist;
}

sub test_resultfile_list($) {
    # get a list of existing resultfiles
    my ($testresdir) = @_;

    my @filelist = qw(video.ogv vars.json backend.json serial0.txt autoinst-log.txt);
    my @filelist_existing;
    for my $f (@filelist) {
        if(-e "$testresdir/$f") {
            push(@filelist_existing, $f);
        }
    }
    return @filelist_existing;
}

sub read_test_modules {
    my ($job) = @_;

    my $testresultdir = $job->result_dir();
    return [] unless $testresultdir;

    my @modlist;

    for my $module (OpenQA::Schema::Result::JobModules::job_modules($job)) {
        my $name = $module->name();
        # add link to $testresultdir/$name*.png via png CGI
        my @imglist;
        my @wavlist;
        my $num = 1;
        for my $img (@{$module->details}) {
            $img->{num} = $num++;
            if( $img->{screenshot} ) {
                push(@imglist, $img);
            }
            elsif( $img->{audio} ) {
                push(@wavlist, $img);
            }
        }

        # add link to $testresultdir/$name*.txt as direct link
        my @ocrlist;
        for my $ocrpath (<$testresultdir/$name-[0-9]*.txt>) {
            $ocrpath = data_name($ocrpath);
            my $ocrscreenshotid = $ocrpath;
            $ocrscreenshotid=~s/^\w+-(\d+)/$1/;
            my $ocrres = $module->{screenshots}->[--$ocrscreenshotid]->{ocr_result} || 'na';
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

    return \@modlist;
}

sub show {
    my ($self) = @_;

    return $self->reply->not_found if (!defined $self->param('testid'));

    my $job = $self->app->schema->resultset("Jobs")->search(
        {
            'id' => $self->param('testid')
        },
        { 'prefetch' => qw/jobs_assets/ }
    )->first;

    return $self->reply->not_found unless $job;

    $self->stash(testname => $job->settings_hash->{NAME});
    $self->stash(distri => $job->settings_hash->{DISTRI});
    $self->stash(version => $job->settings_hash->{VERSION});
    $self->stash(build => $job->settings_hash->{BUILD});

    #  return $self->reply->not_found unless (-e $self->stash('resultdir'));

    # If it's running
    if ($job->state =~ /^(?:running|waiting)$/) {
        $self->stash(worker => $job->worker);
        $self->stash(job => $job);
        $self->stash('backend_info', decode_json($job->backend_info || '{}'));
        $self->render('test/running');
        return;
    }

    my $clone_of = $self->app->schema->resultset("Jobs")->find({ clone_id => $job->id });

    my $modlist = read_test_modules($job);
    $self->stash(job => $job);
    $self->stash(clone_of => $clone_of);
    $self->stash(modlist => $modlist);

    my $rd = $job->result_dir();
    if ($rd) { # saved anything
        # result files box
        my @resultfiles = test_resultfile_list($job->result_dir());

        # uploaded logs box
        my @ulogs = test_uploadlog_list($job->result_dir());

        $self->stash(resultfiles => \@resultfiles);
        $self->stash(ulogs => \@ulogs);
    }
    else {
        $self->stash(resultfiles => []);
        $self->stash(ulogs => []);
    }

    $self->render('test/result');
}

sub _caclulate_preferred_machines {
    my ($jobs) = @_;
    my %machines;
    while (my $job = $jobs->next()) {
        my $sh = $job->settings_hash;
        $machines{$sh->{ARCH}} ||= {};
        $machines{$sh->{ARCH}}->{$sh->{MACHINE}}++;
    }
    my $pms = {};
    for my $arch (keys %machines) {
        my $max = 0;
        for my $machine (keys %{$machines{$arch}}) {
            if ($machines{$arch}->{$machine} > $max) {
                $max = $machines{$arch}->{$machine};
                $pms->{$arch} = $machine;
            }
        }
    }
    $jobs->reset();
    return $pms;
}

# Custom action enabling the openSUSE Release Team
# to see the quality at a glance
sub overview {
    my $self  = shift;
    my $validation = $self->validation;

    my %search_args;
    my $group;
    my $distri;
    my $version;

    if ($self->param('groupid')) {
        $group = $self->db->resultset("JobGroups")->find($self->param('groupid'));
        return $self->reply->not_found if (!$group);
        $search_args{groupid} = $group->id;
    }
    else {
        $validation->required('distri');
        $validation->required('version');
        if ($validation->has_error) {
            return $self->render(text => 'Missing parameters', status => 404);
        }
        $distri = $self->param('distri');
        $version = $self->param('version');

        %search_args = (distri => $distri, version => $version);

        my $flavor = $self->param('flavor');
        if ($flavor) {
            $search_args{flavor} = $flavor;
        }
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

    my $jobs = OpenQA::Scheduler::query_jobs(%search_args);

    my $all_result_stats = OpenQA::Schema::Result::JobModules::job_module_stats($jobs);
    my $preferred_machines = _caclulate_preferred_machines($jobs);

    while (my $job = $jobs->next) {
        my $settings = $job->settings_hash;
        my $testname = $settings->{NAME};
        my $test     = $job->test;
        my $flavor   = $settings->{FLAVOR} || 'sweet';
        my $arch     = $settings->{ARCH}   || 'noarch';

        my $result;
        if ( $job->state eq 'done' ) {
            my $result_stats = $all_result_stats->{$job->id};
            my $overall      = $job->result;
            if ( $job->result eq "passed" && $result_stats->{dents} ) {
                $overall = "softfail";
            }
            $result = {
                passed  => $result_stats->{passed},
                unknown => $result_stats->{unk},
                failed  => $result_stats->{failed},
                dents   => $result_stats->{dents},
                overall => $overall,
                jobid   => $job->id,
                state   => "done",
                failures => $job->failed_modules_with_needles(),
            };
            $aggregated->{$overall}++;
        }
        elsif ( $job->state eq 'running' ) {
            $result = {
                state    => "running",
                jobid    => $job->id,
            };
            $aggregated->{running}++;
        }
        else {
            $result = {
                state    => $job->state,
                jobid    => $job->id,
                priority => $job->priority,
            };
            if ( $job->state eq 'scheduled' ) {
                $aggregated->{scheduled}++;
            }
            else {
                $aggregated->{none}++;
            }
        }

        # Populate @configs and %archs
        if ($preferred_machines->{$settings->{ARCH}} ne $settings->{MACHINE}) {
            $test .= "@" . $settings->{MACHINE};
        }
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
        group => $group,
        configs => \@configs,
        types   => \@types,
        archs   => \%archs,
        results => \%results,
        aggregated => $aggregated
    );
}

1;
# vim: set sw=4 et:
