# Copyright 2015-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::JobModules;

use strict;
use warnings;

use 5.012;    # so readdir assigns to $_ in a lone while test
use base 'DBIx::Class::Core';

use OpenQA::Log qw(log_debug);
use OpenQA::Jobs::Constants;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::File qw(path tempfile);
use Mojo::Util 'decode';
use File::Basename qw(dirname basename);
use File::Path 'remove_tree';
use Cwd 'abs_path';
use Try::Tiny;

__PACKAGE__->table('job_modules');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
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
    always_rollback => {
        data_type => 'integer',
        is_nullable => 0,
        default_value => 0
    },
    result => {
        data_type => 'varchar',
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
        join_type => "LEFT",
        on_update => "CASCADE",
    },
);
__PACKAGE__->add_unique_constraint([qw(job_id name category script)]);

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    $sqlt_table->add_index(name => 'idx_job_modules_result', fields => ['result']);
}

sub results {
    my ($self, %options) = @_;
    my $skip_text_data = $options{skip_text_data};

    my $dir = $self->job->result_dir;
    return undef unless $dir;
    my $name = $self->name;
    my $file_name = "$dir/details-$name.json";
    my $initial_file_size = -s $file_name;
    my $json_data = eval { path($file_name)->slurp };
    if (my $error = $@) {
        log_debug("Unable to read $file_name: $error");
        return {};
    }
    my $json = eval { decode_json($json_data) } // {};
    log_debug("Malformed JSON file $file_name") if $@;

    # load detail file which restores all results provided by os-autoinst (with hash-root)
    # support also old format which only restores details information (with array-root)
    my $results = ref($json) eq 'HASH' ? $json : {details => $json};
    my $details = $results->{details};

    # when the job module is running, the content of the details file is {"result" => "running"}
    # so set details to []
    if (ref $details ne 'ARRAY') {
        $results->{details} = [];
        return $results;
    }

    for my $step (@$details) {
        my $text_file_name = $step->{text};
        if (!$skip_text_data && $text_file_name && !defined $step->{text_data}) {
            eval { $step->{text_data} = decode('UTF-8', path($dir, $text_file_name)->slurp); };
            if (my $error = $@) {
                # try reading the results one more time if the JSON file's size has increased; otherwise render an error
                # note: Likely a concurrent finalize_job_results Minion job has finished so the separate text file has
                #       just been incorporated within the JSON file.
                return $self->results(%options) if (-s $file_name // -1) > ($initial_file_size // -1);
                $step->{text_data} = "Unable to read $text_file_name.";
            }
        }

        next unless $step->{screenshot};
        my $link = abs_path("$dir/$step->{screenshot}");
        next unless $link;
        my $base = basename($link);
        my $dir = dirname($link);
        # if linking into images, translate it into md5 lookup
        if ($dir =~ m,/images/,) {
            $dir =~ s,^.*/images/,,;
            $step->{md5_dirname} = $dir;
            $step->{md5_basename} = $base;
        }
    }

    return $results;
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
    return $result;
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
    my ($self, $screenshot, $known_md5_sums) = @_;

    my ($full, $thumb) = OpenQA::Utils::image_md5_filename($screenshot->{md5});
    my $result_dir = $self->job->result_dir;
    my $screenshot_name = $screenshot->{name};
    $known_md5_sums->{$screenshot->{md5}} = 1 if defined $known_md5_sums && -e $full;
    symlink($full, "$result_dir/$screenshot_name");
    symlink($thumb, "$result_dir/.thumbs/$screenshot_name");
    return $screenshot_name;
}

sub save_results {
    my ($self, $results, $known_md5_sums, $known_file_names) = @_;
    my @dbpaths;
    my $details = $results->{details};
    my $result_dir = $self->job->result_dir;
    for my $d (@$details) {
        # create symlinks for screenshots
        if (my $screenshot = $d->{screenshot}) {
            # save the database entry for the screenshot first
            push(@dbpaths, OpenQA::Utils::image_md5_filename($screenshot->{md5}, 1));
            # create possibly stale symlinks
            $d->{screenshot} = $self->_save_details_screenshot($screenshot, $known_md5_sums);
            next;
        }
        # report other files as known if already present
        next unless defined $known_file_names;
        if (my $other_file = $d->{text} || $d->{audio}) {
            $known_file_names->{$other_file} = 1 if -e "$result_dir/$other_file";
        }
    }
    $self->result_source->schema->resultset('Screenshots')->populate_images_to_job(\@dbpaths, $self->job_id);
    $self->store_needle_infos($details);
    path($self->job->result_dir, 'details-' . $self->name . '.json')->spurt(encode_json($results));
}

# incorporate textual step data into details JSON
# note: Can not be called from save_results() because the upload must have already been concluded.
sub finalize_results {
    my ($self) = @_;

    # locate details JSON; skip if not present or empty
    my $dir = $self->job->result_dir;
    return undef unless $dir;
    my $name = $self->name;
    my $file = path($dir, "details-$name.json");
    return undef unless -s $file;

    # read details; skip if none present
    my $results = decode_json($file->slurp);
    my $details = ref $results eq 'HASH' ? $results->{details} : $results;
    return undef unless ref $details eq 'ARRAY' && @$details;

    # incorporate textual step data into details
    for my $step (@$details) {
        next unless my $text = $step->{text};
        my $txtfile = path($dir, $text);
        next unless -e $txtfile;
        $step->{text_data} = decode('UTF-8', $txtfile->slurp);
    }

    # replace file contents on disk using a temp file to preserve old file if something goes wrong
    my $new_file_contents = encode_json($results);
    my $tmpfile = tempfile(DIR => $file->dirname);
    $tmpfile->spurt($new_file_contents);
    $tmpfile->chmod(0644)->move_to($file);

    # cleanup incorporated files
    for my $step (@$details) {
        next unless $step->{text} && defined $step->{text_data};
        my $textfile = path($dir, $step->{text});
        $textfile->remove if -e $textfile;
    }
}

1;
