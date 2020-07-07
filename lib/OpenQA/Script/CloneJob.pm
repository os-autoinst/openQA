# Copyright (C) 2018-2020 SUSE LLC
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
# You should have received a copy of the GNU General Public License

package OpenQA::Script::CloneJob;

use strict;
use warnings;

use Cpanel::JSON::XS;
use Data::Dump 'pp';
use Exporter 'import';
use LWP::UserAgent;
use OpenQA::Client;
use Mojo::File 'path';
use Mojo::URL;
use Mojo::JSON;    # booleans

our @EXPORT = qw(
  clone_job
  clone_job_apply_settings
  clone_job_get_job
  clone_job_download_assets
  split_jobid
);

use constant GLOBAL_SETTINGS => ('WORKER_CLASS');

use constant JOB_SETTING_OVERRIDES => {
    _GROUP    => '_GROUP_ID',
    _GROUP_ID => '_GROUP',
};

sub is_global_setting {
    return grep /^$_[0]$/, GLOBAL_SETTINGS;
}

sub clone_job_apply_settings {
    my ($argv, $depth, $settings, $options) = @_;

    delete $settings->{NAME};    # usually autocreated
    $settings->{is_clone_job} = 1;    # used to figure out if this is a clone operation

    for my $arg (@$argv) {
        # split arg into key and value
        unless ($arg =~ /([A-Z0-9_]+)=(.*)/) {
            warn "arg '$arg' does not match";
            next;
        }
        my ($key, $value) = ($1, $2);

        next unless (is_global_setting($key) or $depth == 0 or $options->{'parental-inheritance'});

        # delete key if value empty
        if (!defined $value || $value eq '') {
            delete $settings->{$key};
            next;
        }

        # assign value to key, delete overrides
        $settings->{$key} = $value;
        if (my $override = JOB_SETTING_OVERRIDES->{$key}) {
            delete $settings->{$override};
        }
    }
}

sub clone_job_get_job {
    my ($jobid, $remote, $remote_url, $options) = @_;

    my $job;
    my $url = $remote_url->clone;
    $url->path("jobs/$jobid");
    my $tx = $remote->max_redirects(3)->get($url);
    if (!$tx->error) {
        if ($tx->res->code == 200) {
            $job = $tx->res->json->{job};
        }
        else {
            warn sprintf("unexpected return code: %s %s", $tx->res->code, $tx->res->message);
            exit 1;
        }
    }
    else {
        my $err = $tx->error;
        # there is no code for some error reasons, e.g. 'connection refused'
        $err->{code} //= '';
        warn "failed to get job '$jobid': $err->{code} $err->{message}";
        exit 1;
    }

    print Cpanel::JSON::XS->new->pretty->encode($job) if $options->{verbose};
    return $job;
}

sub clone_job_download_assets {
    my ($jobid, $job, $remote, $remote_url, $ua, $options) = @_;
    my @parents = map { clone_job_get_job($_, $remote, $remote_url, $options) } @{$job->{parents}->{Chained}};
  ASSET:
    for my $type (keys %{$job->{assets}}) {
        next if $type eq 'repo';    # we can't download repos
        for my $file (@{$job->{assets}->{$type}}) {
            my $dst = $file;
            # skip downloading published assets assuming we are also cloning
            # the generation job or if the only cloned job *is* the generation
            # job.
            my $nr_parents = @parents;
            if ((!$options->{'skip-deps'} && !$options->{'skip-chained-deps'}) || ($nr_parents == 0)) {
                for my $j (@parents, $job) {
                    next ASSET if $j->{settings}->{PUBLISH_HDD_1} && $file eq $j->{settings}->{PUBLISH_HDD_1};
                }
            }
            $dst =~ s,.*/,,;
            $dst = join('/', $options->{dir}, $type, $dst);
            my $from = $remote_url->clone;
            $from->path(sprintf '/tests/%d/asset/%s/%s', $jobid, $type, $file);
            $from = $from->to_string;

            die "can't write $options->{dir}/$type\n" unless -w "$options->{dir}/$type";

            print "downloading\n$from\nto\n$dst\n";
            my $r = $ua->mirror($from, $dst);
            unless ($r->is_success || $r->code == 304) {
                die "$jobid failed: ", $r->status_line, "\n";
            }

            # ensure the asset cleanup preserves the asset the configured amount of days starting from the time
            # it has been cloned (otherwise old assets might be cleaned up directly again after cloning)
            path($dst)->touch;
        }
    }
}

sub split_jobid {
    my ($url_string) = @_;
    my $url = Mojo::URL->new($url_string);

    # handle scheme being omitted and support specifying only a domain (e.g. 'openqa.opensuse.org')
    $url->scheme('http')               unless $url->scheme;
    $url->host($url->path->parts->[0]) unless $url->host;

    my $host_url = Mojo::URL->new->scheme($url->scheme)->host($url->host)->port($url->port)->to_string;
    (my $jobid) = $url->path =~ /([0-9]+)/;
    return ($host_url, $jobid);
}

sub create_url_handler {
    my ($options) = @_;

    my $ua = LWP::UserAgent->new;
    $ua->timeout(10);
    $ua->env_proxy;
    $ua->show_progress(1) if ($options->{'show-progress'});

    my $local_url;
    if ($options->{'host'} !~ '/') {
        $local_url = Mojo::URL->new();
        $local_url->host($options->{'host'});
        $local_url->scheme('http');
    }
    else {
        $local_url = Mojo::URL->new($options->{'host'});
    }
    $local_url->path('/api/v1/jobs');
    my $local = OpenQA::Client->new(
        api       => $local_url->host,
        apikey    => $options->{'apikey'},
        apisecret => $options->{'apisecret'});

    my $remote_url;
    if ($options->{'from'} !~ '/') {
        $remote_url = Mojo::URL->new();
        $remote_url->host($options->{'from'});
        $remote_url->scheme('http');
    }
    else {
        $remote_url = Mojo::URL->new($options->{'from'});
    }
    $remote_url->path('/api/v1/jobs');
    my $remote = OpenQA::Client->new(api => $options->{host});

    return ($ua, $local, $local_url, $remote, $remote_url);
}

sub openqa_baseurl {
    my ($local_url) = @_;
    my $port = '';
    if (
        $local_url->port
        && (   ($local_url->scheme eq 'http' && $local_url->port != 80)
            || ($local_url->scheme eq 'https' && $local_url->port != 443)))
    {
        $port = ':' . $local_url->port;
    }
    return $local_url->scheme . '://' . $local_url->host . $port;
}

sub clone_job {
    my ($jobid, $options, $clone_map, $depth) = @_;
    $clone_map //= {};
    $depth     //= 0;
    return $clone_map->{$jobid} if defined $clone_map->{$jobid};

    my ($ua, $local, $local_url, $remote, $remote_url) = create_url_handler($options);
    my $job = clone_job_get_job($jobid, $remote, $remote_url, $options);
    if ($job->{parents}) {
        my ($chained, $directly_chained, $parallel);
        unless ($options->{'skip-deps'}) {
            unless ($options->{'skip-chained-deps'}) {
                $chained          = $job->{parents}->{Chained};
                $directly_chained = $job->{parents}->{'Directly chained'};
            }
            $parallel = $job->{parents}->{Parallel};
        }
        $chained          //= [];
        $directly_chained //= [];
        $parallel         //= [];

        print "Cloning dependencies of $job->{name}\n" if (@$chained || @$directly_chained || @$parallel);
        for my $dependencies ($chained, $directly_chained, $parallel) {
            clone_job($_, $options, $clone_map, $depth + 1) for @$dependencies;
        }

        my @new_chained          = map { $clone_map->{$_} } @$chained;
        my @new_directly_chained = map { $clone_map->{$_} } @$directly_chained;
        my @new_parallel         = map { $clone_map->{$_} } @$parallel;

        $job->{settings}->{_PARALLEL_JOBS}             = join(',', @new_parallel)         if @new_parallel;
        $job->{settings}->{_START_AFTER_JOBS}          = join(',', @new_chained)          if @new_chained;
        $job->{settings}->{_START_DIRECTLY_AFTER_JOBS} = join(',', @new_directly_chained) if @new_directly_chained;
    }

    clone_job_download_assets($jobid, $job, $remote, $remote_url, $ua, $options)
      unless $options->{'skip-download'};

    my $url      = $local_url->clone;
    my %settings = %{$job->{settings}};
    if (my $group_id = $job->{group_id}) {
        $settings{_GROUP_ID} = $group_id;
    }
    clone_job_apply_settings($options->{args}, $depth, \%settings, $options);

    print Cpanel::JSON::XS->new->pretty->encode(\%settings) if ($options->{verbose});
    $url->query(%settings);
    my $tx = $local->max_redirects(3)->post($url);
    if (!$tx->error) {
        my $r = $tx->res->json->{id};
        if ($r) {
            my $url = openqa_baseurl($local_url) . '/t' . $r;
            print "Created job #$r: $job->{name} -> $url\n";
            $clone_map->{$jobid} = $r;
            return $r;
        }
        else {
            die "job not created. duplicate? ", pp($tx->res->body);
        }
    }
    else {
        die "Failed to create job, empty response. Make sure your HTTP proxy is running, e.g. apache, nginx, etc."
          unless $tx->res->body;
        die "Failed to create job: ", pp($tx->res->body);
    }
}

1;
