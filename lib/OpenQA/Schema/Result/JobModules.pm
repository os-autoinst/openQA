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
use Data::Dumper;

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
    return $schema->resultset("JobModules")->search({ job_id => $job->{id}, name => $name })->first;
}

sub job_modules($) {
    my ($job) = @_;

    my $schema = Scheduler::schema();
    return $schema->resultset("JobModules")->search({ job_id => $job->{id} })->all;
}

sub job_module_stats($) {
    my ($job) = @_;

    my $result_stat = { 'passed' => 0, 'failed' => 0, 'dents' => 0, 'none' => 0 };

    my $schema = Scheduler::schema();

    my $query = $schema->resultset("JobModules")->search(
        { job_id => $job->{id} },
        {
            select => ['result', 'soft_failure', { 'count' => 'id' } ],
            as => [qw/result soft_failure count/],
            group_by => [qw/result soft_failure/]
        }
    );

    while (my $line = $query->next) {
        if ($line->soft_failure) {
            $result_stat->{dents} = $line->get_column('count');
        }
        else {
            $result_stat->{$line->result} = $line->get_column('count');
        }
    }

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
        _insert_tm($schema, $job, $tm);
    }
}

sub running_modinfo($) {
    my ($job) = @_;

    my @modules = Schema::Result::JobModules::job_modules($job);

    my $currentstep = $job->{running};
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
        if ($name eq $currentstep) {
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

1;
# vim: set sw=4 et:
