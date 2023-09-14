# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Needle::Save;
use Mojo::Base 'Mojolicious::Plugin';

use File::Copy;
use Encode 'encode_utf8';
use OpenQA::Git;
use OpenQA::Jobs::Constants;
use OpenQA::Utils;
use Mojo::JSON 'decode_json';

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(save_needle => sub { _save_needle($app, @_) });
}

sub _json_validation {
    my ($json) = @_;

    my $djson = eval { decode_json($json) };
    if (!$djson) {
        my $err = $@;
        $err =~ s@at /usr/.*$@@;    # do not print perl module reference
        die "syntax error: $err";
    }
    if (!exists $djson->{area} || !exists $djson->{area}[0]) {
        die 'no area defined';
    }
    if (!exists $djson->{tags} || !exists $djson->{tags}[0]) {
        die 'no tag defined';
    }

    my $areas = $djson->{area};
    foreach my $area (@$areas) {
        die 'area without xpos' unless exists $area->{xpos};
        die 'area without ypos' unless exists $area->{ypos};
        die 'area without type' unless exists $area->{type};
        die 'area without height' unless exists $area->{height};
        die 'area without width' unless exists $area->{width};
        if ($area->{type} eq 'ocr') {
          die 'OCR area without refstr' unless exists $area->{refstr};
          die 'refstr is an empty string' if ($area->{refstr} eq '');
          die 'refstr contains placeholder char §' if ($area->{refstr} =~ qr/§/);
        }
    }
    return $djson;
}

sub _format_git_error {
    my ($name, $error) = @_;
    return "<strong>Failed to save $name.</strong><br><pre>$error</pre>";
}

sub _save_needle {
    my ($app, $minion_job, $args) = @_;

    # prevent multiple save_needle and delete_needles tasks to run in parallel
    return $minion_job->finish({error => 'Another save or delete needle job is ongoing. Try again later.'})
      unless my $guard = $app->minion->guard('limit_needle_task', 7200);

    my $schema = $app->schema;
    my $openqa_job = $schema->resultset('Jobs')->find($args->{job_id});
    my $user = $schema->resultset('Users')->find($args->{user_id});
    my $needle_json = encode_utf8($args->{needle_json});
    my $imagedir = $args->{imagedir};
    my $imagedistri = $args->{imagedistri};
    my $imagename = $args->{imagename};
    my $imageversion = $args->{imageversion};
    my $needledir = $args->{needledir};
    my $needlename = $args->{needlename};
    my $commit_message = $args->{commit_message};

    # read JSON data
    my $json_data;
    eval { $json_data = _json_validation($needle_json); };
    if ($@) {
        my $error = $@;
        $app->log->error("Error validating needle: $error");
        return $minion_job->finish({error => "<strong>Failed to validate $needlename.</strong><br>$error"});
    }

    my @match_areas = grep { $_->{type} eq 'match' } @{$json_data->{area}};
    my $no_match_areas = not scalar(@match_areas);

    my $imagepath;
    unless ($no_match_areas) {
        # determine imagepath
        if ($imagedir) {
            $imagepath = join('/', $imagedir, $imagename);
        }
        elsif ($imagedistri) {
            $imagepath = join('/', needledir($imagedistri, $imageversion), $imagename);
        }
        else {
            $imagepath = join('/', $openqa_job->result_dir(), $imagename);
        }
        if (!-f $imagepath) {
            my $error = "Image $imagename could not be found!";
            $app->log->error("Failed to save needle: $error");
            return $minion_job->fail({error => "<strong>Failed to save $needlename.</strong><br>$error"});
        }
    }

    # check whether needle directory actually exists
    if (!$needledir || !(-d $needledir)) {
        return $minion_job->fail({error => $needledir ? "$needledir is not a directory" : 'no needle directory'});
    }

    # ensure needle dir is up-to-date
    my $git = OpenQA::Git->new({app => $app, dir => $needledir, user => $user});
    if ($git->enabled) {
        my $error = $git->set_to_latest_master;
        if ($error) {
            $app->log->error($error);
            return $minion_job->fail({error => _format_git_error($needlename, $error)});
        }
    }

    # do not overwrite the exist needle if disallow to overwrite
    my $baseneedle = "$needledir/$needlename";
    if (-e "$baseneedle.json" && !$args->{overwrite}) {
        #my $returned_data = $self->req->params->to_hash;
        #$returned_data->{requires_overwrite} = 1;
        return $minion_job->finish({requires_overwrite => 1});
    }

    my $success = 1;
    unless ($no_match_areas) {
        # copy image
        if (!($imagepath eq "$baseneedle.png") && !copy($imagepath, "$baseneedle.png")) {
            $app->log->error("Copy $imagepath -> $baseneedle.png failed: $!");
            $success = 0;
        }
    }
    if ($success) {
        open(my $J, ">", "$baseneedle.json") or $success = 0;
        if ($success) {
            print($J $needle_json);
            close($J);
        }
        else {
            $app->log->error("Writing needle $baseneedle.json failed: $!");
        }
    }
    return $minion_job->fail({error => "<strong>Error creating/updating needle:</strong><br>$!."}) unless $success;

    # commit needle in Git repository
    if ($git->enabled) {
        my @files_to_be_comm = ["$needlename.json"];
        push(@files_to_be_comm, "$needlename.png") unless $no_match_areas;
        my $error = $git->commit(
            {
                add => @files_to_be_comm,
                message => ($commit_message || sprintf("%s for %s", $needlename, $openqa_job->name)),
            });
        if ($error) {
            $app->log->error($error);
            return $minion_job->fail({error => _format_git_error($needlename, $error)});
        }
    }

    # create/update needle in database
    $schema->resultset('Needles')->update_needle_from_editor($needledir, $needlename, $json_data, $openqa_job);

    # finish minion job with successful result
    my $info = {
        success => "Needle $needlename created/updated",
        json_data => $json_data,
    };
    if ($openqa_job->state eq OpenQA::Jobs::Constants::RUNNING && $openqa_job->developer_session) {
        $info->{developer_session_job_id} = $openqa_job->id;
    }
    if ($openqa_job->can_be_duplicated) {
        $info->{propose_restart} = 1;
    }
    return $minion_job->finish($info);
}

1;
