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

package OpenQA::Schema::Result::JobModules;
use base qw/DBIx::Class::Core/;

use strict;
use db_helpers;
use OpenQA::Scheduler;
use OpenQA::Schema::Result::Jobs;
use JSON ();

__PACKAGE__->table('job_modules');
__PACKAGE__->load_components(qw/InflateColumn::DateTime Timestamps/);
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    job_id => {
        data_type => 'integer',
        is_foreign_key => 1,
    },
    name => {
        data_type => 'text',
    },
    script => {
        data_type => 'text',
    },
    category => {
        data_type => 'text',
    },
    # flags - not using a bit field and not using a join table
    # to simplify code. In case we get a much bigger database, we
    # might reconsider
    soft_failure => {
        data_type => 'integer',
        is_nullable => 0,
        default_value => 0
    },
    milestone => {
        data_type => 'integer',
        is_nullable => 0,
        default_value => 0
    },
    important => {
        data_type => 'integer',
        is_nullable => 0,
        default_value => 0
    },
    fatal => {
        data_type => 'integer',
        is_nullable => 0,
        default_value => 0
    },
    result => {
        data_type => 'varchar',
        default_value => OpenQA::Schema::Result::Jobs::NONE,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(
    "job",
    "OpenQA::Schema::Result::Jobs",
    { 'foreign.id' => "self.job_id" },
    {
        is_deferrable => 1,
        join_type     => "LEFT",
        on_delete     => "CASCADE",
        on_update     => "CASCADE",
    },
);

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    $sqlt_table->add_index(name => 'idx_job_modules_result', fields => ['result']);
}

sub details() {
    my ($self) = @_;

    my $fn = $self->job->result_dir() . "/details-" . $self->name . ".json";
    OpenQA::Utils::log_debug "reading $fn";
    open(my $fh, "<", $fn) || return [];
    local $/;
    my $ret = JSON::decode_json(<$fh>);
    close($fh);
    return $ret;
}

sub job_module($$) {
    my ($job, $name) = @_;

    my $schema = OpenQA::Scheduler::schema();
    return $schema->resultset("JobModules")->search({ job_id => $job->id, name => $name })->first;
}

sub job_modules($) {
    my ($job) = @_;

    my $schema = OpenQA::Scheduler::schema();
    return $schema->resultset("JobModules")->search({ job_id => $job->id }, { order_by => 'id'} )->all;
}

sub job_module_stats($) {
    my ($jobs) = @_;

    my $result_stat = {};

    my $schema = OpenQA::Scheduler::schema();
    my @ids;
    while (my $j = $jobs->next) { push(@ids, $j->id); }
    $jobs->reset;

    for my $id (@ids) {
        $result_stat->{$id} = { 'passed' => 0, 'failed' => 0, 'dents' => 0, 'none' => 0 };
    }

    # DBIx has a limit for variables in one querey
    while (my @next_ids = splice @ids, 0, 100) {
        my $query = $schema->resultset("JobModules")->search(
            { job_id => { -in => \@next_ids } },
            {
                select => ['job_id', 'result', 'soft_failure', { 'count' => 'id' } ],
                as => [qw/job_id result soft_failure count/],
                group_by => [qw/job_id result soft_failure/]
            }
        );

        while (my $line = $query->next) {
            if ($line->soft_failure) {
                $result_stat->{$line->job_id}->{dents} = $line->get_column('count');
            }
            else {
                $result_stat->{$line->job_id}->{$line->result} =
                  $line->get_column('count');
            }
        }
    }

    return $result_stat;
}

sub update_result($) {
    my ($self, $r) = @_;

    my $result = $r->{result};

    $result ||= 'none';
    $result =~ s,fail,failed,;
    $result =~ s,^na,none,;
    $result =~ s,^ok,passed,;
    $result =~ s,^unk,none,;
    $result =~ s,^skip,skipped,;
    $self->update(
        {
            result => $result,
            soft_failure => $r->{dents}?1:0,
        }
    );
}

sub save_details($) {
    my ($self, $details) = @_;
    my $existant_md5 = [];
    for my $d (@$details) {
        # create possibly stale symlinks
        my ($full, $thumb) = OpenQA::Utils::image_md5_filename($d->{screenshot}->{md5});
        if (-e $full) { # mark existant
            push(@$existant_md5, $d->{screenshot}->{md5});
        }
        symlink($full, $self->job->result_dir . "/" . $d->{screenshot}->{name});
        symlink($thumb, $self->job->result_dir . "/.thumbs/" . $d->{screenshot}->{name});
        $d->{screenshot} = $d->{screenshot}->{name};
    }
    open(my $fh, ">", $self->job->result_dir . "/details-" . $self->name . ".json");
    $fh->print(JSON::encode_json($details));
    close($fh);
    return $existant_md5;
}

1;
# vim: set sw=4 et:
