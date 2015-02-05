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

sub {
    my $schema = shift;

    # Jobs->state
    $schema->resultset('Jobs')->search({ state_id => 0 })->update({ state => OpenQA::Schema::Result::Jobs::SCHEDULED });
    $schema->resultset('Jobs')->search({ state_id => 1 })->update({ state => OpenQA::Schema::Result::Jobs::RUNNING });
    $schema->resultset('Jobs')->search({ state_id => 2 })->update({ state => OpenQA::Schema::Result::Jobs::CANCELLED });
    $schema->resultset('Jobs')->search({ state_id => 3 })->update({ state => OpenQA::Schema::Result::Jobs::WAITING });
    $schema->resultset('Jobs')->search({ state_id => 4 })->update({ state => OpenQA::Schema::Result::Jobs::DONE });
    $schema->resultset('Jobs')->search({ state_id => 5 })->update({ state => OpenQA::Schema::Result::Jobs::OBSOLETED });

    # Jobs->result
    $schema->resultset('Jobs')->search({ result_id => 0 })->update({ result => OpenQA::Schema::Result::Jobs::NONE });
    $schema->resultset('Jobs')->search({ result_id => 1 })->update({ result => OpenQA::Schema::Result::Jobs::PASSED });
    $schema->resultset('Jobs')->search({ result_id => 2 })->update({ result => OpenQA::Schema::Result::Jobs::FAILED });
    $schema->resultset('Jobs')->search({ result_id => 3 })->update({ result => OpenQA::Schema::Result::Jobs::INCOMPLETE });
    $schema->resultset('Jobs')->search({ result_id => 4 })->update({ result => OpenQA::Schema::Result::Jobs::SKIPPED });

    # JobModules->result
    $schema->resultset('JobModules')->search({ result_id => 0 })->update({ result => OpenQA::Schema::Result::Jobs::NONE });
    $schema->resultset('JobModules')->search({ result_id => 1 })->update({ result => OpenQA::Schema::Result::Jobs::PASSED });
    $schema->resultset('JobModules')->search({ result_id => 2 })->update({ result => OpenQA::Schema::Result::Jobs::FAILED });
    $schema->resultset('JobModules')->search({ result_id => 3 })->update({ result => OpenQA::Schema::Result::Jobs::INCOMPLETE });
    $schema->resultset('JobModules')->search({ result_id => 4 })->update({ result => OpenQA::Schema::Result::Jobs::SKIPPED });
  }
