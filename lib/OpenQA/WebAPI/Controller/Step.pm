# Copyright (C) 2014-2016 SUSE LLC
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

package OpenQA::WebAPI::Controller::Step;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::File 'path';
use OpenQA::Utils;
use OpenQA::Jobs::Constants;
use File::Basename;
use File::Copy;
use File::Which 'which';
use POSIX 'strftime';
use Try::Tiny;
use Cpanel::JSON::XS;

sub init {
    my ($self) = @_;

    my $job = $self->app->schema->resultset('Jobs')->find($self->param('testid'));

    return $self->reply->not_found unless $job;
    $self->stash(testname => $job->name);
    $self->stash(distri   => $job->DISTRI);
    $self->stash(version  => $job->VERSION);
    $self->stash(build    => $job->BUILD);

    my $module = OpenQA::Schema::Result::JobModules::job_module($job, $self->param('moduleid'));
    $self->stash('job',    $job);
    $self->stash('module', $module);
}

sub check_tabmode {
    my ($self) = @_;

    my $job       = $self->stash('job');
    my $module    = $self->stash('module');
    my $details   = $module->details();
    my $testindex = $self->param('stepid');

    $self->stash('imglist', $details);

    my $tabmode = 'screenshot';    # Default
    if ($testindex > @$details) {
        # This means that the module have no details at all
        $self->reply->not_found;
        return 0;
    }
    else {
        my $module_detail = $details->[$testindex - 1];
        if ($module_detail->{audio}) {
            $tabmode = 'audio';
        }
        elsif ($module_detail->{text}) {
            my $file = path($job->result_dir(), $module_detail->{text})->open('<:encoding(UTF-8)');
            my @file_content;
            if (defined $file) {
                @file_content = <$file>;
            }
            $self->stash('textresult', "@file_content");
            $tabmode = 'text';
        }
        $self->stash('module_detail', $module_detail);
    }
    $self->stash('tabmode', $tabmode);

    1;
}

# Helper function to generate the needle url, with an optional version
sub needle_url {
    my ($self, $distri, $name, $version, $jsonfile) = @_;

    if (defined($jsonfile) && $jsonfile) {
        if (defined($version) && $version) {
            $self->url_for('needle_file', distri => $distri, name => $name)
              ->query(version => $version, jsonfile => $jsonfile);
        }
        else {
            $self->url_for('needle_file', distri => $distri, name => $name)->query(jsonfile => $jsonfile);
        }
    }
    else {
        if (defined($version) && $version) {
            $self->url_for('needle_file', distri => $distri, name => $name)->query(version => $version);
        }
        else {
            $self->url_for('needle_file', distri => $distri, name => $name);
        }
    }
}

# Call to viewimg or viewaudio
sub view {
    my ($self) = @_;

    # Redirect users with the old preview link
    if (!$self->req->is_xhr) {
        my $anchor = "#step/" . $self->param('moduleid') . "/" . $self->param('stepid');
        my $target_url = $self->url_for('test', testid => $self->param('testid'));
        return $self->redirect_to($target_url . $anchor);
    }

    return 0 unless $self->init() && $self->check_tabmode();

    if ('audio' eq $self->stash('tabmode')) {
        $self->render('step/viewaudio');
    }
    elsif ('text' eq $self->stash('tabmode')) {
        $self->render('step/viewtext');
    }
    else {
        $self->viewimg;
    }
}

# Needle editor
sub edit {
    my ($self) = @_;
    return 0 unless $self->init() && $self->check_tabmode();

    my $module_detail = $self->stash('module_detail');
    my $imgname       = $module_detail->{screenshot};
    my $job           = $self->app->schema->resultset('Jobs')->find($self->param('testid'));
    return $self->reply->not_found unless $job;
    my $distribution = $job->DISTRI;
    my $dversion = $job->VERSION || '';

    # Each object in @needles will contain the name, both the url and the local path
    # of the image and 2 lists of areas: 'area' and 'matches'.
    # The former refers to the original definitions and the later shows the position
    # found (best try) in the actual screenshot.
    # The first element of the needles array is the screenshot itself, with an empty
    # 'areas' (there is no needle associated to the screenshot) and with all matching
    # areas in 'matches'.
    my @needles;

    my @error_messages;
    my $tags = $module_detail->{tags} // [];
    my $screenshot;
    my %basic_needle_data = (
        tags       => $tags,
        distri     => $distribution,
        version    => $dversion,
        image_name => $imgname,
    );

    if (my $needle_name = $module_detail->{needle}) {
        # First position: the screenshot with all the matching areas (in result)
        $screenshot = $self->_new_screenshot($tags, $imgname, $module_detail->{area});

        # Second position: the only needle (with the same matches)
        my $needle_info = $self->_extended_needle_info($needle_name, \%basic_needle_data, $module_detail->{json}, 0,
            \@error_messages);
        if ($needle_info) {
            $needle_info->{matches} = $screenshot->{matches};
            push(@needles, $needle_info);
        }
    }
    if ($module_detail->{needles}) {
        # First position: the screenshot
        $screenshot = $self->_new_screenshot($tags, $imgname);

        # Afterwards: all the candidate needles
        # $needle contains information from result, in which 'areas' refers to the best matches.
        # We also use $area for transforming the match information into a real area
        for my $needle (@{$module_detail->{needles}}) {
            my $needle_info
              = $self->_extended_needle_info($needle->{name}, \%basic_needle_data, $needle->{json},
                $needle->{error}, \@error_messages)
              || next;
            for my $match (@{$needle->{area}}) {
                my $area = {
                    xpos   => int $match->{x},
                    width  => int $match->{w},
                    ypos   => int $match->{y},
                    height => int $match->{h},
                    type   => 'match',
                };
                $area->{margin} = int($match->{margin}) if defined $match->{margin};
                $area->{match}  = int($match->{match})  if defined $match->{match};
                push(@{$needle_info->{matches}}, $area);
            }
            push(@needles, $needle_info);
        }
    }

    # handle case when failing with not a single candidate needle
    $screenshot //= $self->_new_screenshot($tags, $imgname);

    # sort needles: the highest matches first
    @needles = sort { $b->{avg_similarity} <=> $a->{avg_similarity} || $a->{name} cmp $b->{name} } @needles;

    # check whether new needles with matching tags have already been created since the job has been started
    if (@$tags) {
        my $new_needles = $self->app->schema->resultset('Needles')->new_needles_since($job->t_started, $tags, 5);
        while (my $new_needle = $new_needles->next) {
            my $new_needle_tags = $new_needle->tags;
            my $joined_tags = $new_needle_tags ? join(', ', @$new_needle_tags) : 'none';
            # show warning for new needle with matching tags
            push(
                @error_messages,
                sprintf(
                    'A new needle with matching tags has been created since the job started: %s (tags: %s)',
                    $new_needle->filename, $joined_tags
                ));
            # get needle info to show the needle also in selection
            my $needle_info
              = $self->_extended_needle_info($new_needle->name, \%basic_needle_data, $new_needle->path, undef,
                \@error_messages)
              || next;
            $needle_info->{title} = 'new: ' . $needle_info->{title};
            push(@needles, $needle_info);
        }
    }

    # set default values
    #  - area: matches from best candidate
    #  - tags: tags from the screenshot
    my $default_needle = {};
    my $first_needle   = $needles[0];
    if ($first_needle && ($first_needle->{avg_similarity} || 0) > 70) {
        $first_needle->{selected}     = 1;
        $default_needle->{tags}       = $first_needle->{tags};
        $default_needle->{area}       = $first_needle->{matches};
        $default_needle->{properties} = $first_needle->{properties};
        $screenshot->{suggested_name} = $first_needle->{suggested_name};
    }
    else {
        $screenshot->{selected}       = 1;
        $default_needle->{tags}       = $screenshot->{tags};
        $default_needle->{area}       = [];
        $default_needle->{properties} = [];
        my $name = $self->param('moduleid');
        if (@{$screenshot->{tags}}) {
            my $ftag = $screenshot->{tags}->[0];
            # concat the module name and the tag unless the tag already starts
            # with the module name
            if ($ftag =~ m/^$name/) {
                $name = $ftag;
            }
            else {
                $name .= "-$ftag";
            }
        }
        $screenshot->{suggested_name} = ensure_timestamp_appended($name);
    }

    # clear tags, area and matches of screenshot and prepend it to needles
    $screenshot->{tags} = $screenshot->{area} = $screenshot->{matches} = [];
    unshift(@needles, $screenshot);

    # stash properties
    my $properties = {};
    for my $property (@{$default_needle->{properties}}) {
        $properties->{$property} = $property;
    }
    $self->stash('needles',        \@needles);
    $self->stash('tags',           $tags);
    $self->stash('properties',     $properties);
    $self->stash('default_needle', $default_needle);
    $self->stash('error_messages', \@error_messages);
    $self->render('step/edit');
}

sub _new_screenshot {
    my ($self, $tags, $image_name, $matches) = @_;

    my %screenshot = (
        name       => 'screenshot',
        title      => 'Screenshot',
        imagename  => $image_name,
        imagedir   => '',
        imageurl   => $self->url_for('test_img', filename => $image_name)->to_string(),
        area       => [],
        matches    => [],
        properties => [],
        json       => '',
        tags       => $tags,
    );
    return \%screenshot unless $matches;

    for my $area (@$matches) {
        push(
            @{$screenshot{matches}},
            {
                xpos   => int $area->{x},
                width  => int $area->{w},
                ypos   => int $area->{y},
                height => int $area->{h},
                type   => 'match'
            });
    }
    return \%screenshot;
}

sub _extended_needle_info {
    my ($self, $needle_name, $basic_needle_data, $file_name, $error, $error_messages) = @_;

    my $overall_list_of_tags = $basic_needle_data->{tags};
    my $distri               = $basic_needle_data->{distri};
    my $version              = $basic_needle_data->{version};
    my $needle_info          = needle_info($needle_name, $distri, $version, $file_name);
    if (!$needle_info) {
        my $error_message = sprintf('Could not parse needle: %s for %s %s', $needle_name, $distri, $version);
        $self->app->log->error($error_message);
        push(@$error_messages, $error_message);
        return;
    }

    $needle_info->{title}          = $needle_name;
    $needle_info->{suggested_name} = ensure_timestamp_appended($needle_name);
    $needle_info->{imageurl}
      = $self->needle_url($distri, $needle_name . '.png', $version, $needle_info->{json})->to_string();
    $needle_info->{imagename}    = basename($needle_info->{image});
    $needle_info->{imagedir}     = dirname($needle_info->{image});
    $needle_info->{imagedistri}  = $distri;
    $needle_info->{imageversion} = $version;
    $needle_info->{tags}       //= [];
    $needle_info->{matches}    //= [];
    $needle_info->{properties} //= [];
    $needle_info->{json}       //= '';

    $error //= $needle_info->{error};
    if (defined $error) {
        $needle_info->{avg_similarity} = map_error_to_avg($error);
        $needle_info->{title}          = $needle_info->{avg_similarity} . '%: ' . $needle_name;
    }
    for my $tag (@{$needle_info->{tags}}) {
        push(@$overall_list_of_tags, $tag) unless grep(/^$tag$/, @$overall_list_of_tags);
    }

    return $needle_info;
}

sub src {
    my ($self) = @_;

    return 0 unless $self->init();

    my $job    = $self->stash('job');
    my $module = $self->stash('module');

    my $testcasedir = testcasedir($job->DISTRI, $job->VERSION);
    my $scriptpath = "$testcasedir/" . $module->script;
    if (!$scriptpath || !-e $scriptpath) {
        $scriptpath ||= "";
        return $self->reply->not_found;
    }
    my $script_h = path($scriptpath)->open('<:encoding(UTF-8)');
    my @script_content;
    if (defined $script_h) {
        @script_content = <$script_h>;
    }
    my $script = "@script_content";

    $self->stash('script',     $script);
    $self->stash('scriptpath', $scriptpath);
}

sub _commit_git {
    my ($self, $job, $dir, $name) = @_;

    my @files = ($dir . '/' . $name . '.json', $dir . '/' . $name . '.png');

    my $args = {
        dir     => $dir,
        add     => \@files,
        user    => $self->current_user,
        message => sprintf("%s for %s", $name, $job->name)};
    if (!commit_git($args)) {
        die "failed to git commit $name";
    }
    return;
}

sub _json_validation($) {

    my $self  = shift;
    my $json  = shift;
    my $djson = eval { decode_json($json) };
    if (!$djson) {
        my $err = $@;
        $err =~ s@at /usr/.*$@@;    #do not print perl module reference
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

sub save_needle_ajax {
    my ($self) = @_;
    return 0 unless $self->init();

    # validate parameter
    my $validation = $self->validation;
    $validation->required('json');
    $validation->required('imagename')->like(qr/^[^.\/][^\/]{3,}\.png$/);
    $validation->optional('imagedistri')->like(qr/^[^.\/]+$/);
    $validation->optional('imageversion')->like(qr/^(?!.*([.])\1+).*$/);
    $validation->optional('imageversion')->like(qr/^[^\/]+$/);
    $validation->required('needlename')->like(qr/^[^.\/][^\/]{3,}$/);
    if ($validation->has_error) {
        my $error = 'wrong parameters:';
        for my $k (qw(json imagename imagedistri imageversion needlename)) {
            $self->app->log->error($k . ' ' . join(' ', @{$validation->error($k)})) if $validation->has_error($k);
            $error .= ' ' . $k if $validation->has_error($k);
        }
        return $self->render(json => {error => "Error creating/updating needle: $error"});
    }

    # read parameter
    my $job          = find_job($self, $self->param('testid')) or return;
    my $distribution = $job->DISTRI;
    my $dversion     = $job->VERSION || '';
    my $json         = $validation->param('json');
    my $imagename    = $validation->param('imagename');
    my $imagedistri  = $validation->param('imagedistri');
    my $imageversion = $validation->param('imageversion');
    my $imagedir     = $self->param('imagedir') || "";
    my $needlename   = $validation->param('needlename');
    my $needledir    = needledir($job->DISTRI, $job->VERSION);

    # read JSON data
    my $json_data;
    eval { $json_data = $self->_json_validation($json); };
    if ($@) {
        my $message = 'Error validating needle: ' . $@;
        $self->app->log->error($message);
        return $self->render(json => {error => $message});
    }

    # determine imagepath
    my $success = 1;
    my $imagepath;
    if ($imagedir) {
        $imagepath = join('/', $imagedir, $imagename);
    }
    elsif ($imagedistri) {
        $imagepath = join('/', needledir($imagedistri, $imageversion), $imagename);
    }
    else {
        $imagepath = join('/', $job->result_dir(), $imagename);
    }
    if (!-f $imagepath) {
        $self->app->log->error("$imagepath is not a file");
        return $self->render(json => {error => "Image $imagename could not be found!"});
    }

    # do not overwrite the exist needle if disallow to overwrite
    my $baseneedle = "$needledir/$needlename";
    if (-e "$baseneedle.png" && !$self->param('overwrite')) {
        $success = 0;
        my $returned_data = $self->req->params->to_hash;
        $returned_data->{requires_overwrite} = 1;
        return $self->render(json => $returned_data);
    }

    # copy image
    if (!($imagepath eq "$baseneedle.png") && !copy($imagepath, "$baseneedle.png")) {
        $self->app->log->error("Copy $imagepath -> $baseneedle.png failed: $!");
        $success = 0;
    }
    if ($success) {
        open(my $J, ">", "$baseneedle.json") or $success = 0;
        if ($success) {
            print $J $json;
            close($J);
        }
        else {
            $self->app->log->error("Writing needle $baseneedle.json failed: $!");
        }
    }
    if (!$success) {
        return $self->render(json => {error => "Error creating/updating needle: $!."});
    }

    # commit needle in Git repository
    $self->app->gru->enqueue('scan_needles');
    if (($self->app->config->{global}->{scm} || '') eq 'git') {
        if (!$needledir || !(-d "$needledir")) {
            return $self->render(json => {error => "$needledir is not a directory"});
        }
        try {
            $self->_commit_git($job, $needledir, $needlename);
        }
        catch {
            $self->app->log->error($_);
            return $self->render(json => {error => $_});
        };
    }

    # create/update needle in database
    $self->app->schema->resultset('Needles')->update_needle_from_editor($needledir, $needlename, $json_data, $job);

    $self->emit_event('openqa_needle_modify', {needle => "$baseneedle.png", tags => $json_data->{tags}, update => 0});
    my $info = {info => "Needle $needlename created/updated"};
    if ($job->state eq OpenQA::Jobs::Constants::RUNNING && $job->developer_session) {
        $info->{developer_session_job_id} = $job->id;
    }
    if ($job->can_be_duplicated) {
        $info->{restart} = $self->url_for('apiv1_restart', jobid => $job->id);
    }
    return $self->render(json => $info);
}

sub map_error_to_avg {
    my ($error) = @_;

    return int((1 - sqrt($error // 0)) * 100 + 0.5);
}

sub calc_matches {
    my ($needle, $areas) = @_;

    for my $area (@$areas) {
        my $sim = int($area->{similarity} + 0.5);
        push(
            @{$needle->{matches}},
            {
                xpos       => int $area->{x},
                width      => int $area->{w},
                ypos       => int $area->{y},
                height     => int $area->{h},
                type       => $area->{result},
                similarity => $sim
            });
    }
    $needle->{avg_similarity} //= map_error_to_avg($needle->{error});
    return;
}

sub viewimg {
    my $self          = shift;
    my $module_detail = $self->stash('module_detail');
    my $job           = $self->stash('job');
    return $self->reply->not_found unless $job;
    my $distribution = $job->DISTRI;
    my $dversion = $job->VERSION || '';

    # initialize hash to store needle lists by tags
    my %needles_by_tag;
    for my $tag (@{$module_detail->{tags}}) {
        $needles_by_tag{$tag} = [];
    }

    my $append_needle_info = sub {
        my ($tags, $needle_info) = @_;

        # handle case when the needle has (for some reason) no tags
        if (!$tags) {
            push(@{$needles_by_tag{'tags unknown'} //= []}, $needle_info);
            return;
        }

        # ensure we have a label assigned
        $needle_info->{label} //= $needle_info->{avg_similarity} . '%: ' . $needle_info->{name};

        # add the needle info to tags ...
        for my $tag (@$tags) {
            # ... but only to tags the test was actually looking for
            if (my $needles = $needles_by_tag{$tag}) {
                push(@$needles, $needle_info);
            }
        }
    };

    # load primary needle match
    my $primary_match;
    if (my $needle = $module_detail->{needle}) {
        if (my $needleinfo = needle_info($needle, $distribution, $dversion, $module_detail->{json})) {
            my $info = {
                name          => $needle,
                image         => $self->needle_url($distribution, $needle . '.png', $dversion, $needleinfo->{json}),
                areas         => $needleinfo->{area},
                error         => $module_detail->{error},
                matches       => [],
                primary_match => 1,
                selected      => 1,
            };
            calc_matches($info, $module_detail->{area});
            $primary_match = $info;
            $append_needle_info->($needleinfo->{tags} => $info);
        }
    }

    # load other needle matches
    if ($module_detail->{needles}) {
        for my $needle (@{$module_detail->{needles}}) {
            my $needlename = $needle->{name};
            my $needleinfo = needle_info($needlename, $distribution, $dversion, $needle->{json});
            next unless $needleinfo;
            my $info = {
                name    => $needlename,
                image   => $self->needle_url($distribution, "$needlename.png", $dversion, $needleinfo->{json}),
                error   => $needle->{error},
                areas   => $needleinfo->{area},
                matches => [],
            };
            calc_matches($info, $needle->{area});
            $append_needle_info->($needleinfo->{tags} => $info);
        }
    }

    # sort needles by average similarity
    my $has_selection = defined($primary_match);
    for my $tag (keys %needles_by_tag) {
        my @sorted_needles = sort { $b->{avg_similarity} <=> $a->{avg_similarity} || $a->{name} cmp $b->{name} }
          @{$needles_by_tag{$tag}};
        $needles_by_tag{$tag} = \@sorted_needles;

        # preselect a rather good needle
        # note: the same needle can be shown under different tags, hence the selected flag might be occur twice
        #       (even though we check for $has_selection here!)
        my $best_match = $sorted_needles[0];
        if (!$has_selection && $best_match && $best_match->{avg_similarity} > 70) {
            $has_selection = $best_match->{selected} = 1;
            $primary_match = $best_match;
        }
    }

    $self->stash('screenshot',     $module_detail->{screenshot});
    $self->stash('frametime',      $module_detail->{frametime});
    $self->stash('default_label',  $primary_match ? $primary_match->{label} : 'Screenshot');
    $self->stash('needles_by_tag', \%needles_by_tag);
    $self->stash('tag_count',      scalar %needles_by_tag);
    return $self->render('step/viewimg');
}

1;
# vim: set sw=4 et:
