# Copyright (C) 2015 SUSE LLC
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

use strict;
use OpenQA::Schema::Schema;
use Data::Dump;
use v5.10;
use DBIx::Class::DeploymentHandler;
use Date::Format qw/time2str/;
use Getopt::Long;
use OpenQA::Utils;
use OpenQA::Scheduler::Scheduler;
use JSON "decode_json";
use Cwd "realpath";


sub {
    my $schema = shift;

    my $modules = $schema->resultset("JobModules")->search({result => {'!=', OpenQA::Schema::Result::Jobs::NONE}}, {order_by => 'me.id ASC'});

    my %first_seen;
    my %last_match;
    my %last_seen;
    my $last_job;
    while (my $module = $modules->next) {
        my $j;
        # avoid repeated job queries
        if ($last_job && $last_job->id == $module->job_id) {
            $j = $last_job;
        }
        else {
            $j = $last_job = $module->job;
        }
        my $fn = join('/', $j->result_dir, 'details-' . $module->name . '.json');
        #print "FN $fn\n";
        next unless -e $fn;
        open(my $fd, '<', $fn);
        next unless $fd;
        local $/;    # enable localized slurp mode
        my $details;
        eval { $details = decode_json(<$fd>) };
        close $fd;
        if ($@ || !$details) {
            warn "failed to parse $fn";
            next;
        }
        my $distri  = $j->settings_hash->{DISTRI};
        my $version = $j->settings_hash->{VERSION};
        my $dir     = OpenQA::Utils::testcasedir($distri, $version);

        for my $detail (@{$details}) {
            if ($detail->{needle}) {
                my $nfn = realpath("$dir/needles/$detail->{needle}.json");
                $first_seen{$nfn} ||= $module->id;
                $last_match{$nfn} = $module->id;
                $last_seen{$nfn}  = $module->id;
            }
            for my $needle (@{$detail->{needles} || []}) {
                $needle = $needle->{name};
                my $nfn = realpath("$dir/needles/$needle.json");
                $first_seen{$nfn} ||= $module->id;
                $last_seen{$nfn} = $module->id;
            }
        }
    }
    for my $nfn (keys %first_seen) {
        $schema->resultset('Needles')->create(
            {
                filename               => $nfn,
                first_seen_module_id   => $first_seen{$nfn},
                last_seen_module_id    => $last_seen{$nfn},
                last_matched_module_id => $last_match{$nfn}});
    }
  }

