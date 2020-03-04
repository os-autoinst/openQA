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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Schema::Result::JobModules;

use strict;
use warnings;

use 5.012;    # so readdir assigns to $_ in a lone while test
use base 'DBIx::Class::Core';

use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::File 'path';
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
__PACKAGE__->add_unique_constraint([qw(job_id name category script)]);

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

sub details {
    my ($self) = @_;

    my $dir = $self->job->result_dir();
    return unless $dir;
    my $fn = "$dir/details-" . $self->name . ".json";
    OpenQA::Utils::log_debug "reading $fn";
    open(my $fh, "<", $fn) || return {};
    local $/;
    my $ret;
    # decode_json dies if JSON is malformed, so handle that
    try {
        $ret = decode_json(<$fh>);
    }
    catch {
        OpenQA::Utils::log_debug "malformed JSON file $fn";
        $ret = {};
    }
    finally {
        close($fh);
    };
    my $details = ref($ret) eq 'HASH' ? $ret : {results => $ret, execution_time => ''};
    for my $img (@{$details->{results}}) {
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

    return $details;
}

sub job_module {
    my ($job, $name) = @_;

    my $schema = OpenQA::Schema->singleton;
    return $schema->resultset("JobModules")->search({job_id => $job->id, name => $name})->first;
}

sub job_modules {
    my ($job) = @_;

    my $schema = OpenQA::Schema->singleton;
    return $schema->resultset("JobModules")->search({job_id => $job->id}, {order_by => 'id'})->all;
}

sub update_result {
    my ($self, $r) = @_;
    my $result = $r->{result} || 'none';
    $result =~ s,fail,failed,;
    $result =~ s,^na,none,;
    $result =~ s,^ok,passed,;
    $result =~ s,^unk,none,;
    $result =~ s,^skip,skipped,;
    $result = 'softfailed' if ($r->{dents} && $result eq 'passed');
    $self->update({result => $result});
}

# if you give a needle_cache, make sure to call
# OpenQA::Schema::Result::Needles::update_needle_cache
sub store_needle_infos {
    my ($self, $details, $needle_cache) = @_;

    # we often see the same needles in the same test, so avoid duplicated work
    my %hash;
    $needle_cache = \%hash unless $needle_cache;
    for my $detail (@$details) {
        if ($detail->{needle}) {
            OpenQA::Schema::Result::Needles::update_needle($detail->{json}, $self, 1, $needle_cache);
        }
        for my $needle (@{$detail->{needles} || []}) {
            OpenQA::Schema::Result::Needles::update_needle($needle->{json}, $self, 0, $needle_cache);
        }
    }

    # if it's someone else's cache, he has to be aware
    OpenQA::Schema::Result::Needles::update_needle_cache(\%hash);
}

sub _save_details_screenshot {
    my ($self, $screenshot, $existent_md5) = @_;

    my ($full, $thumb) = OpenQA::Utils::image_md5_filename($screenshot->{md5});
    push(@$existent_md5, $screenshot->{md5}) if (-e $full);    # mark existent
    symlink($full,  $self->job->result_dir . "/" . $screenshot->{name});
    symlink($thumb, $self->job->result_dir . "/.thumbs/" . $screenshot->{name});
    return $screenshot->{name};
}

sub save_details {
    my ($self, $details) = @_;
    my $existent_md5 = [];
    my @dbpaths;
    my $results = ref($details) eq 'HASH' ? $details->{results} : $details;
    for my $d (@$results) {
        # avoid creating symlinks for text results
        if ($d->{screenshot}) {
            # save the database entry for the screenshot first
            push(@dbpaths, OpenQA::Utils::image_md5_filename($d->{screenshot}->{md5}, 1));
            # create possibly stale symlinks
            $d->{screenshot} = $self->_save_details_screenshot($d->{screenshot}, $existent_md5);
        }
    }
    $self->result_source->schema->resultset('Screenshots')->populate_images_to_job(\@dbpaths, $self->job_id);

    $self->store_needle_infos($results);
    path($self->job->result_dir, 'details-' . $self->name . '.json')->spurt(encode_json($details));
    return $existent_md5;
}

1;
