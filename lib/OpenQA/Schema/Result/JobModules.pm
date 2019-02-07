# Copyright (C) 2015-2016 SUSE LLC
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

use strict;
use warnings;

use 5.012;    # so readdir assigns to $_ in a lone while test
use base 'DBIx::Class::Core';

use db_helpers;
use OpenQA::Scheduler::Scheduler;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use Mojo::JSON qw(decode_json encode_json);
use File::Basename qw(dirname basename);
use File::Path 'remove_tree';
use Cwd 'abs_path';
use Try::Tiny;

__PACKAGE__->table('job_modules');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    job_id => {
        data_type      => 'integer',
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
    milestone => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0
    },
    important => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0
    },
    fatal => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0
    },
    always_rollback => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0
    },
    result => {
        data_type     => 'varchar',
        default_value => OpenQA::Jobs::Constants::NONE,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(
    "job",
    "OpenQA::Schema::Result::Jobs",
    {'foreign.id' => "self.job_id"},
    {
        is_deferrable => 1,
        join_type     => "LEFT",
        on_update     => "CASCADE",
    },
);

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    $sqlt_table->add_index(name => 'idx_job_modules_result', fields => ['result']);
}

my %columns_by_result = (
    OpenQA::Jobs::Constants::PASSED     => 'passed_module_count',
    OpenQA::Jobs::Constants::SOFTFAILED => 'softfailed_module_count',
    OpenQA::Jobs::Constants::FAILED     => 'failed_module_count',
    OpenQA::Jobs::Constants::NONE       => 'skipped_module_count',
    OpenQA::Jobs::Constants::SKIPPED    => 'externally_skipped_module_count',
);

# override to update job module stats in jobs table
sub store_column {
    my ($self, $name, $value) = @_;

    # only updates of result relevant here
    if (!($name eq 'result' || $name eq 'job_id')) {
        return $self->next::method($name, $value);
    }

    # set default result to 'none'
    $value //= OpenQA::Jobs::Constants::NONE if ($name eq 'result');

    # remember previous value before updating
    my $previous_value = $self->get_column($name);
    my $res            = $self->next::method($name, $value);

    # skip this when the value does not change
    if ($value && $previous_value && $value eq $previous_value) {
        return $res;
    }

    # update statistics in relevant job(s)
    if ($name eq 'result') {
        # update assigned job on result change
        my $job = $self->job or return $res;
        my %job_update;
        if (my $value_column = $columns_by_result{$value}) {
            $job_update{$value_column} = $job->get_column($value_column) + 1;
        }
        if ($previous_value) {
            if (my $previous_value_column = $columns_by_result{$previous_value}) {
                $job_update{$previous_value_column} = $job->get_column($previous_value_column) - 1;
            }
        }
        $job->update(\%job_update);

    }
    elsif ($name eq 'job_id') {
        # update previous job and new job on job assignment
        # handling previous job might not be neccassary because once a job is assigned, it shouldn't
        # change anymore, right?
        my $result = $self->result or return $res;
        my $result_column = $columns_by_result{$result} or return $res;
        if ($previous_value) {
            if (my $previous_job = $self->result_source->schema->resultset('Jobs')->find($previous_value)) {
                $previous_job->update({$result_column => $previous_job->get_column($result_column) - 1});
            }
        }
        if ($value) {
            if (my $job = $self->result_source->schema->resultset('Jobs')->find($value)) {
                $job->update({$result_column => $job->get_column($result_column) + 1});
            }
        }
    }

    return $res;
}

# override to update job module stats in jobs table
sub insert {
    my ($self, @args) = @_;
    $self->next::method(@args);

    # count modules which are initially skipped (default value for the result) in statistics of associated job
    # doing this explicitely is required because in this case store_column does not seem to be called
    my $job    = $self->job;
    my $result = $self->result;
    if ($job && (!$result || $result eq OpenQA::Jobs::Constants::NONE)) {
        $job->update({skipped_module_count => $job->skipped_module_count + 1});
    }

    return $self;
}

sub details {
    my ($self) = @_;

    my $dir = $self->job->result_dir();
    return unless $dir;
    my $fn = "$dir/details-" . $self->name . ".json";
    OpenQA::Utils::log_debug "reading $fn";
    open(my $fh, "<", $fn) || return [];
    local $/;
    my $ret;
    # decode_json dies if JSON is malformed, so handle that
    try {
        $ret = decode_json(<$fh>);
    }
    catch {
        OpenQA::Utils::log_debug "malformed JSON file $fn";
        $ret = [];
    }
    finally {
        close($fh);
    };
    for my $img (@$ret) {
        next unless $img->{screenshot};
        my $link = abs_path($dir . "/" . $img->{screenshot});
        next unless $link;
        my $base = basename($link);
        my $dir  = dirname($link);
        # if linking into images, translate it into md5 lookup
        if ($dir =~ m,/images/,) {
            $dir =~ s,^.*/images/,,;
            $img->{md5_dirname}  = $dir;
            $img->{md5_basename} = $base;
        }
    }

    return $ret;
}

sub job_module {
    my ($job, $name) = @_;

    my $schema = OpenQA::Scheduler::Scheduler::schema();
    return $schema->resultset("JobModules")->search({job_id => $job->id, name => $name})->first;
}

sub job_modules {
    my ($job) = @_;

    my $schema = OpenQA::Scheduler::Scheduler::schema();
    return $schema->resultset("JobModules")->search({job_id => $job->id}, {order_by => 'id'})->all;
}

sub update_result {
    my ($self, $r) = @_;

    my $result = $r->{result};

    $result ||= 'none';
    $result =~ s,fail,failed,;
    $result =~ s,^na,none,;
    $result =~ s,^ok,passed,;
    $result =~ s,^unk,none,;
    $result =~ s,^skip,skipped,;
    if ($r->{dents} && $result eq 'passed') {
        $result = 'softfailed';
    }
    $self->update(
        {
            result => $result,
        });
}

# if you give a needle_cache, make sure to call
# OpenQA::Schema::Result::Needles::update_needle_cache
sub store_needle_infos {
    my ($self, $details, $needle_cache) = @_;

    my $schema = $self->result_source->schema;

    # we often see the same needles in the same test, so avoid duplicated work
    my %hash;
    if (!$needle_cache) {
        $needle_cache = \%hash;
    }

    my %needles;

    for my $detail (@{$details}) {
        if ($detail->{needle}) {
            my $nfn    = $detail->{json};
            my $needle = OpenQA::Schema::Result::Needles::update_needle($nfn, $self, 1, $needle_cache);
            $needles{$needle->id} ||= 1;
        }
        for my $needle (@{$detail->{needles} || []}) {
            my $nfn    = $needle->{json};
            my $needle = OpenQA::Schema::Result::Needles::update_needle($nfn, $self, 0, $needle_cache);
            # failing needles are more interesting than succeeding, so ignore previous values
            $needles{$needle->id} = -1;
        }
    }

    # if it's someone else's cache, he has to be aware
    OpenQA::Schema::Result::Needles::update_needle_cache(\%hash);
}

sub _save_details_screenshot {
    my ($self, $screenshot, $existent_md5, $cleanup) = @_;

    my ($full, $thumb) = OpenQA::Utils::image_md5_filename($screenshot->{md5});
    if (-e $full) {    # mark existent
        push(@$existent_md5, $screenshot->{md5});
    }
    if ($cleanup) {
        # interactive mode, recreate the symbolic link of screenshot if it was changed
        my $full_link  = readlink($self->job->result_dir . "/" . $screenshot->{name})         || '';
        my $thumb_link = readlink($self->job->result_dir . "/.thumbs/" . $screenshot->{name}) || '';
        if ($full ne $full_link) {
            OpenQA::Utils::log_debug "cleaning up " . $self->job->result_dir . "/" . $screenshot->{name};
            unlink($self->job->result_dir . "/" . $screenshot->{name});
        }
        if ($thumb ne $thumb_link) {
            OpenQA::Utils::log_debug "cleaning up " . $self->job->result_dir . "/.thumbs/" . $screenshot->{name};
            unlink($self->job->result_dir . "/.thumbs/" . $screenshot->{name});
        }
    }
    symlink($full,  $self->job->result_dir . "/" . $screenshot->{name});
    symlink($thumb, $self->job->result_dir . "/.thumbs/" . $screenshot->{name});
    return $screenshot->{name};
}

sub save_details {
    my ($self, $details, $cleanup) = @_;
    my $existent_md5 = [];
    my @dbpaths;
    my $schema = $self->result_source->schema;
    for my $d (@$details) {
        # avoid creating symlinks for text results
        if ($d->{screenshot}) {
            # save the database entry for the screenshot first
            push(@dbpaths, OpenQA::Utils::image_md5_filename($d->{screenshot}->{md5}, 1));
            # create possibly stale symlinks
            $d->{screenshot} = $self->_save_details_screenshot($d->{screenshot}, $existent_md5, $cleanup);
        }
    }
    OpenQA::Schema::Result::ScreenshotLinks::populate_images_to_job($schema, \@dbpaths, $self->job_id);

    $self->store_needle_infos($details);
    open(my $fh, ">", $self->job->result_dir . "/details-" . $self->name . ".json");
    $fh->print(encode_json($details));
    close($fh);
    return $existent_md5;
}

1;
# vim: set sw=4 et:
