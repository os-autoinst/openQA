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

package Schema::Result::JobModules;
use base qw/DBIx::Class::Core/;

use db_helpers;
use Scheduler;
use Schema::Result::Jobs;

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
        default_value => Schema::Result::Jobs::NONE,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(
    "job",
    "Schema::Result::Jobs",
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

sub _count_job_results($$) {
    my ($job, $result) = @_;

    my $schema = Scheduler::schema();

    my $rid = $result_cache{$result};
    my $count = $schema->resultset("JobModules")->search({ job_id => $job->{id}, result => $result })->count;
}

sub job_module_stats($) {
    my ($job) = @_;

    # TODO: this can be pretty trivially optimized
    my $result_stat = {};
    $result_stat->{'ok'} = _count_job_results($job, 'passed');
    $result_stat->{'fail'} = _count_job_results($job, 'failed');
    $result_stat->{'na'} = _count_job_results($job, 'none');
    $result_stat->{'unk'} = _count_job_results($job, 'incomplete');

    return $result_stat;
}

sub _insert_tm($$$) {
    my ($schema, $job, $tm) = @_;
    $tm->{details} = []; # ignore
    my $r = $schema->resultset("JobModules")->find_or_new(
        {
            job_id => $job->{id},
            script => $tm->{script}
        }
    );
    if (!$r->in_storage) {
        $r->category($tm->{category});
        $r->name($tm->{name});
        $r->insert;
    }
    my $result = $tm->{result};
    $result =~ s,fail,failed,;
    $result =~ s,^na,none,;
    $result =~ s,^ok,passed,;
    $result =~ s,^unk,none,;
    $result =~ s,^skip,skipped,;
    my $soft_failure;
    $soft_failure = 1 if $tm->{dents}; # it's just a flag
    $r->update(
        {
            result => $result,
            milestone => $tm->{flags}->{milestone},
            important => $tm->{flags}->{important},
            fatal => $tm->{flags}->{fatal},
            soft_failure => $soft_failure
        }
    );


}

sub split_results($;$) {
    my ($job,$results) = @_;

    $results ||= openqa::test_result($job->{settings}->{NAME});
    return unless $results; # broken test
    my $schema = Scheduler::schema();
    for my $tm (@{$results->{testmodules}}) {
        _insert_tm($schema, $job, $tm);
    }
}

1;
# vim: set sw=4 et:
