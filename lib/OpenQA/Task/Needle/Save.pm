# Copyright (C) 2019 SUSE LLC
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

package OpenQA::Task::Needle::Save;
use Mojo::Base 'Mojolicious::Plugin';

use File::Copy;
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
        die 'area without xpos'   unless exists $area->{xpos};
        die 'area without ypos'   unless exists $area->{ypos};
        die 'area without type'   unless exists $area->{type};
        die 'area without height' unless exists $area->{height};
        die 'area without width'  unless exists $area->{width};
    }
    return $djson;
}

sub _format_git_error {
    my ($name, $error) = @_;
    return "<strong>Failed to save $name.</strong><br><pre>$error</pre>";
}

sub _save_needle {
    my ($app, $minion_job, $args) = @_;

    # prevent multiple save_needle tasks to run in parallel
    return $minion_job->fail({error => 'Another save needle job is ongoing. Try again later.'})
      unless my $guard = $app->minion->guard('limit_save_needle_task', 300);

    my $schema       = $app->schema;
    my $openqa_job   = $schema->resultset('Jobs')->find($args->{job_id});
    my $user         = $schema->resultset('Users')->find($args->{user_id});
    my $needle_json  = $args->{needle_json};
    my $imagedir     = $args->{imagedir};
    my $imagedistri  = $args->{imagedistri};
    my $imagename    = $args->{imagename};
    my $imageversion = $args->{imageversion};
    my $needledir    = $args->{needledir};
    my $needlename   = $args->{needlename};

    # read JSON data
    my $json_data;
    eval { $json_data = _json_validation($needle_json); };
    if ($@) {
        my $error = $@;
        $app->log->error("Error validating needle: $error");
        return $minion_job->fail({error => "<strong>Failed to validate $needlename.</strong><br>$error"});
    }

    # determine imagepath
    my $imagepath;
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

    # check whether needle directory actually exists
    if (!$needledir || !(-d $needledir)) {
        return $minion_job->fail({error => $needledir ? "$needledir is not a directory" : 'no needle directory'});
    }

    # ensure needle dir is up-to-date
    my $save_via_git = ($app->config->{global}->{scm} || '') eq 'git';
    if ($save_via_git) {
        my $error = set_to_latest_git_master({dir => $needledir});
        if ($error) {
            $app->log->error($error);
            return $minion_job->fail({error => _format_git_error($needlename, $error)});
        }
    }

    # do not overwrite the exist needle if disallow to overwrite
    my $baseneedle = "$needledir/$needlename";
    if (-e "$baseneedle.png" && !$args->{overwrite}) {
        #my $returned_data = $self->req->params->to_hash;
        #$returned_data->{requires_overwrite} = 1;
        return $minion_job->fail({requires_overwrite => 1});
    }

    # copy image
    my $success = 1;
    if (!($imagepath eq "$baseneedle.png") && !copy($imagepath, "$baseneedle.png")) {
        $app->log->error("Copy $imagepath -> $baseneedle.png failed: $!");
        $success = 0;
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
    if ($save_via_git) {
        my $error = commit_git(
            {
                dir     => $needledir,
                add     => ["$needledir/$needlename.json", "$needledir/$needlename.png"],
                user    => $user,
                message => sprintf("%s for %s", $needlename, $openqa_job->name),
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
        success   => "Needle $needlename created/updated",
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
