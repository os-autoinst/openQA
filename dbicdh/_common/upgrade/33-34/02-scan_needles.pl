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
use v5.10;
use DBIx::Class::DeploymentHandler;

sub {
    my $schema = shift;

    my $query = undef;
    #$query = { id => { '>', 155000 } };
    my $jobs = $schema->resultset("Jobs")->search($query, {order_by => 'me.id ASC'});

    my %needle_cache;

    while (my $job = $jobs->next) {
        my $modules = $job->modules->search({"me.result" => {'!=', OpenQA::Schema::Result::Jobs::NONE}}, {order_by => 'me.id ASC'});
        while (my $module = $modules->next) {

            $module->job($job);
            my $details = $module->details();
            next unless $details;

            $module->store_needle_infos($details, \%needle_cache);
        }
    }
    OpenQA::Schema::Result::Needles::update_needle_cache(\%needle_cache);
  }

