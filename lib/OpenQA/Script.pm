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

package OpenQA::Script;

use strict;
use warnings;

use Cpanel::JSON::XS;
use Exporter 'import';
use Mojo::File 'path';

our @EXPORT = qw(
  clone_job_apply_settings
  clone_job_get_job
  clone_job_download_assets
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

    for my $arg (@$argv) {
        # split arg into key and value
        unless ($arg =~ /([A-Z0-9_]+)=(.*)/) {
            warn "arg $arg doesn't match";
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

1;
