# Copyright 2015-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::JobModules;

use Mojo::Base 'DBIx::Class::Core', -signatures;

use OpenQA::Jobs::Constants;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::File qw(path tempfile);
use Mojo::Util 'decode';
use File::Basename qw(dirname basename);
use File::Path 'remove_tree';
use Cwd 'abs_path';
use Feature::Compat::Try;

__PACKAGE__->table('job_modules');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'bigint',
        is_auto_increment => 1,
    },
    job_id => {
        data_type => 'bigint',
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
    'job',
    'OpenQA::Schema::Result::Jobs',
    {'foreign.id' => 'self.job_id'},
    {
        is_deferrable => 1,
        join_type => 'LEFT',
        on_update => 'CASCADE',
    },
);
__PACKAGE__->add_unique_constraint([qw(job_id name category script)]);

sub sqlt_deploy_hook ($self, $sqlt_table) {
    $sqlt_table->add_index(name => 'idx_job_modules_result', fields => ['result']);
}

sub results ($self, %options) {
    my $skip_text_data = $options{skip_text_data};

    return {} unless my $dir = $self->job->result_dir;
    my $name = $self->name;

    my $file = path($dir, "details-$name.json");
    my $json_data;
    try { $json_data = $file->slurp }
    catch ($e) { return {} }

    my $json;
    try { $json = decode_json($json_data) }
    catch ($e) { die qq{Malformed/unreadable JSON file "$file": $e} }
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
            my $text_file = path($dir, $text_file_name);
            $step->{text_data} = do {
                try { decode('UTF-8', $text_file->slurp) }
                catch ($e) { "Unable to read $text_file_name." }
            };
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

sub update_result ($self, $r) {
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
sub store_needle_infos ($self, $details, $needle_cache = undef) {

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

sub _save_details_screenshot ($self, $screenshot, $known_md5_sums) {
    my ($full, $thumb) = OpenQA::Utils::image_md5_filename($screenshot->{md5});
    my $result_dir = $self->job->result_dir;
    my $screenshot_name = $screenshot->{name};
    $known_md5_sums->{$screenshot->{md5}} = 1 if defined $known_md5_sums && -e $full;
    symlink($full, "$result_dir/$screenshot_name");
    symlink($thumb, "$result_dir/.thumbs/$screenshot_name");
    return $screenshot_name;
}

sub save_results ($self, $results, $known_md5_sums = undef, $known_file_names = undef) {
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

    my $dir = $self->job->result_dir;
    my $tmpfile = tempfile(DIR => $dir);
    $tmpfile->spew(encode_json($results))->chmod(0644)->move_to(path($dir, 'details-' . $self->name . '.json'));
}

# incorporate textual step data into details JSON
# note: Can not be called from save_results() because the upload must have already been concluded.
sub finalize_results ($self) {
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
        my $txtdata;
        try { $txtdata = decode('UTF-8', $txtfile->slurp) }
        catch ($e) { }
        $step->{text_data} = $txtdata if defined $txtdata;
    }

    # replace file contents on disk using a temp file to preserve old file if something goes wrong
    my $new_file_contents = encode_json($results);
    my $tmpfile = tempfile(DIR => $file->dirname);
    $tmpfile->spew($new_file_contents);
    $tmpfile->chmod(0644)->move_to($file);

    # cleanup incorporated files
    for my $step (@$details) {
        next unless $step->{text} && defined $step->{text_data};
        my $textfile = path($dir, $step->{text});
        $textfile->remove if -e $textfile;
    }
}

1;
