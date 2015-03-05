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

#!perl

use strict;
use warnings;

use JSON qw/encode_json decode_json/;
use OpenQA::Utils;

sub _test_result($) {
    my ($testresdir) = @_;
    open(JF, "<", "$testresdir/results.json") || return;
    use Fcntl;
    return unless fcntl(JF, F_SETLKW, pack('ssqql', F_RDLCK, 0, 0, 0, $$));
    my $result_hash;
    local $/;
    eval {$result_hash = JSON::decode_json(<JF>);};
    warn "failed to parse $testresdir/results.json: $@" if $@;
    close(JF);
    return $result_hash;
}

sub split_results {
    my ($job, $dir) = @_;

    my $results = _test_result($dir);
    return unless $results; # broken test
    my $schema = OpenQA::Scheduler::schema();
    for my $tm (@{$results->{testmodules}}) {
        my $r = $job->insert_module($tm);
        if ($results->{running} && $r->name eq $results->{running}) {
            $tm->{result} = 'running';
        }
        $r->update_result($tm);
        my $fn = $dir . "/details-" . $r->name . ".json";
        if (open(my $fh, ">", $fn)) {
            $fh->print(encode_json($tm->{details}));
            close($fh);
        }
        else {
            warn "$fn: $!\n";
        }
    }
    return $results;
}

# copy a fixed version of NAME function so we can change the NAME later
sub name {
    my $job = shift;

    my $job_settings = $job->settings_hash;
    my @a;

    my %formats = ('BUILD' => 'Build%s',);

    for my $c (qw/DISTRI VERSION FLAVOR MEDIA ARCH BUILD TEST/) {
        next unless $job_settings->{$c};
        push @a, sprintf(($formats{$c}||'%s'), $job_settings->{$c});
    }
    my $name = join('-', @a);
    $name =~ s/[^a-zA-Z0-9._+:-]/_/g;
    return $name;
}

sub {
    my $schema = shift;

    my $jobs = $schema->resultset('Jobs');
    while (my $job = $jobs->next) {
        my $name = sprintf "%08d-%s", $job->id, name($job);
        my $dir = $OpenQA::Utils::resultdir . "/$name";
        $job->set_column(result_dir => $name);
        my $result = split_results($job, $dir);
        my $bi = $result->{backend};
        if (!$bi && $job->backend_info) {
            $bi = decode_json($job->backend_info);
        }
        $bi ||= { 'backend' => 'qemu', backend_info => {} };
        my $backend = $bi->{backend};
        $backend = 'qemu' if $backend eq 'backend::driver';
        $job->set_column(backend => $backend );
        $job->set_column(backend_info => encode_json($bi->{backend_info}));
        $job->update();
    }

  }

