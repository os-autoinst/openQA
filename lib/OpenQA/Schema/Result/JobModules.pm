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

# TODO: remove asap - and split the details out of results.json
sub details($) {
    my ($self, $testresultdir) = @_;

    my $result = _test_result($testresultdir);
    foreach my $module (@{$result->{'testmodules'}}) {
        my $name = $module->{'name'};
        if ($name eq $self->name) {
            return $module->{'details'};
        }
    }
    return [];
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

sub test_result($) {
    my ($testname) = @_;
    _test_result(OpenQA::Utils::testresultdir($testname));
}

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

    $results ||= test_result($job->{settings}->{NAME});
    return unless $results; # broken test
    my $schema = OpenQA::Scheduler::schema();
    for my $tm (@{$results->{testmodules}}) {
        my $r = $job->_insert_tm($schema, $tm);
        if ($r->name eq $results->{running}) {
            $tm->{result} = 'running';
        }
        $r->update_result($tm);
    }
}

sub running_modinfo($) {
    my ($job) = @_;

    my @modules = OpenQA::Schema::Result::JobModules::job_modules($job);

    my $modlist = [];
    my $donecount = 0;
    my $count = int(@modules);
    my $modstate = 'done';
    my $category;
    for my $module (@modules) {
        my $name = $module->name;
        my $result = $module->result;
        if (!$category || $category ne $module->category) {
            $category = $module->category;
            push(@$modlist, {'category' => $category, 'modules' => []});
        }
        if ($result eq 'running') {
            $modstate = 'current';
        }
        elsif ($modstate eq 'current') {
            $modstate = 'todo';
        }
        elsif ($modstate eq 'done') {
            $donecount++;
        }
        my $moditem = {'name' => $name, 'state' => $modstate, 'result' => $result};
        push(@{$modlist->[scalar(@$modlist)-1]->{'modules'}}, $moditem);
    }
    return {'modlist' => $modlist, 'modcount' => $count, 'moddone' => $donecount, 'running' => $results->{'running'}};
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
    $self->save_details($r->{details});
}

sub save_details($) {
    my ($self, $details) = @_;
    use Data::Dumper;
    for my $d (@$details) {
        OpenQA::Utils::save_base64_png($self->job->resultdir, $d->{screenshot}->{name},$d->{screenshot}->{full});
        OpenQA::Utils::save_base64_png($self->job->resultdir . "/thumbs",$d->{screenshot}->{name}, $d->{screenshot}->{thumb});
        $d->{screenshot} = $d->{screenshot}->{name};
    }
    open(my $fh, ">", $self->job->resultdir . "/details-" . $self->name . ".json");
    $fh->print(JSON::encode_json($details));
    close($fh);
}

1;
# vim: set sw=4 et:
