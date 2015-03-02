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

use OpenQA::Utils;

sub _test_result($) {
    my ($testresdir) = @_;
    local $/;
    open(JF, "<", "$testresdir/results.json") || return;
    use Fcntl;
    return unless fcntl(JF, F_SETLKW, pack('ssqql', F_RDLCK, 0, 0, 0, $$));
    my $result_hash;
    eval {$result_hash = JSON::decode_json(<JF>);};
    warn "failed to parse $testresdir/results.json: $@" if $@;
    close(JF);
    return $result_hash;
}

sub split_results($;$) {
    my ($job,$results) = @_;

    $results ||= _test_result($job->resultdir());
    return unless $results; # broken test
    my $schema = OpenQA::Scheduler::schema();
    for my $tm (@{$results->{testmodules}}) {
        my $r = $job->insert_module($schema, $tm);
        if ($r->name eq $results->{running}) {
            $tm->{result} = 'running';
        }
        $r->update_result($tm);
    }
}

sub {
    my $schema = shift;

    my $jobs = $schema->resultset('Jobs');
    while (my $job = $jobs->next) {
        $job = $job->to_hash();
        OpenQA::Schema::Result::JobModules::split_results($job);
    }

  }

