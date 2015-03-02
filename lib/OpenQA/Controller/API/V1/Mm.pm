# Copyright (c) 2015 SUSE LINUX GmbH, Nuernberg, Germany.
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Controller::API::V1::Mm;
use Mojo::Base 'Mojolicious::Controller';

use strict;
use warnings;

use OpenQA::Schema::Result::Jobs;

sub get_children_status {
    my ($self) = @_;
    my $status = $self->stash('status');
    if ($status eq 'running') {
        $status = OpenQA::Schema::Result::Jobs::RUNNING;
    }
    elsif ($status eq 'scheduled') {
        $status = OpenQA::Schema::Result::Jobs::SCHEDULED;
    }
    else {
        $status = OpenQA::Schema::Result::Jobs::DONE;
    }
    my $jobid = $self->stash('job_id');

    my @res = $self->db->resultset('Jobs')->search({'parents.parent_job_id' => $jobid, state => $status}, {columns => ['id'], join => 'parents'});
    my @res_ids = map {$_->id} @res;
    return $self->render(json => { jobs => \@res_ids }, status => 200);
}

1;
