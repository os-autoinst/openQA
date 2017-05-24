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
use File::Basename;
use File::Copy;
use File::Which 'which';
use POSIX 'strftime';
use Try::Tiny;
use JSON;

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

    $self->stash('modinfo', $job->running_modinfo());
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

    # Each object in $needles will contain the name, both the url and the local path
    # of the image and 2 lists of areas: 'area' and 'matches'.
    # The former refers to the original definitions and the later shows the position
    # found (best try) in the actual screenshot.
    # The first element of the needles array is the screenshot itself, with an empty
    # 'areas' (there is no needle associated to the screenshot) and with all matching
    # areas in 'matches'.
    my @needles;
    my @error_messages;
    # All tags (from all needles)
    my $tags = [];
    $tags = $module_detail->{tags} if ($module_detail->{tags});
    my $screenshot;

    if ($module_detail->{needle}) {

        # First position: the screenshot with all the matching areas (in result)
        $screenshot = {
            name       => 'screenshot',
            imageurl   => $self->url_for('test_img', filename => $module_detail->{screenshot})->to_string,
            imagename  => $imgname,
            imagedir   => "",
            area       => [],
            matches    => [],
            properties => [],
            json       => "",
            tags       => []};
        for my $tag (@$tags) {
            push(@{$screenshot->{tags}}, $tag);
        }
        for my $area (@{$module_detail->{area}}) {
            my $narea = {
                xpos   => int $area->{x},
                width  => int $area->{w},
                ypos   => int $area->{y},
                height => int $area->{h},
                type   => 'match'
            };
            push(@{$screenshot->{matches}}, $narea);
        }
        # Second position: the only needle (with the same matches)
        my $needle = needle_info($module_detail->{needle}, $distribution, $dversion, $module_detail->{json});

        if (!$needle) {
            my $error_message
              = sprintf("Could not find needle: %s for %s %s", $module_detail->{needle}, $distribution, $dversion);
            $self->app->log->error($error_message);
            push(@error_messages, $error_message);
        }
        else {
            my $matched = {
                name           => $module_detail->{needle},
                suggested_name => $self->_timestamp($module_detail->{needle}),
                imageurl =>
                  $self->needle_url($distribution, $module_detail->{needle} . '.png', $dversion, $needle->{json})
                  ->to_string,
                imagename      => basename($needle->{image}),
                imagedir       => dirname($needle->{image}),
                imagedistri    => $needle->{distri},
                imageversion   => $needle->{version},
                area           => $needle->{area},
                avg_similarity => map_error_to_avg($needle->{error}),
                tags           => $needle->{tags},
                json           => $needle->{json} || "",
                properties     => $needle->{properties} || [],
                matches        => $screenshot->{matches}};
            $matched->{title} = $matched->{avg_similarity} . "%: " . $matched->{name};
            push(@needles, $matched);
        }

        for my $t (@{$needle->{tags}}) {
            push(@$tags, $t) unless grep(/^$t$/, @$tags);
        }

    }
    if ($module_detail->{needles}) {

        # First position: the screenshot
        $screenshot = {
            name       => 'screenshot',
            imagename  => $imgname,
            imagedir   => "",
            imageurl   => $self->url_for('test_img', filename => $module_detail->{screenshot})->to_string,
            area       => [],
            matches    => [],
            properties => [],
            json       => "",
            tags       => []};
        for my $tag (@$tags) {
            push(@{$screenshot->{tags}}, $tag);
        }
        # Afterwards, all the candidate needles
        my $needleinfo;
        my $needlename;
        my $area;
        # For each candidate we will use the following variables:
        # $needle: needle information from result, in which 'areas' refers to the best matches
        # $needlename: read from the above
        # $needleinfo: actual definition of the needle, with the original areas
        # We also use $area for transforming the match information intro a real area
        for my $needle (@{$module_detail->{needles}}) {
            $needlename = $needle->{name};
            $needleinfo = needle_info($needlename, $distribution, $dversion || '', $needle->{json});

            if (!defined $needleinfo) {
                my $error_message
                  = sprintf("Could not parse needle: %s for %s %s", $needlename, $distribution, $dversion || '');
                $self->app->log->error($error_message);
                push(@error_messages, $error_message);

                $needleinfo->{image}  = [];
                $needleinfo->{tags}   = [];
                $needleinfo->{area}   = [];
                $needleinfo->{broken} = 1;
            }

            my $needlehash = {
                name           => $needlename,
                title          => $needlename,
                avg_similarity => map_error_to_avg($needle->{error}),
                suggested_name => $self->_timestamp($needlename),
                imageurl =>
                  $self->needle_url($distribution, "$needlename.png", $dversion, $needleinfo->{json})->to_string,
                imagename    => basename($needleinfo->{image}),
                imagedir     => dirname($needleinfo->{image}),
                imagedistri  => $needleinfo->{distri},
                imageversion => $needleinfo->{version},
                tags         => $needleinfo->{tags},
                area         => $needleinfo->{area},
                json         => $needleinfo->{json} || "",
                properties   => $needleinfo->{properties} || [],
                matches      => [],
                broken       => $needleinfo->{broken}};
            push(@needles, $needlehash) unless $needlehash->{broken};
            for my $match (@{$needle->{area}}) {
                $area = {
                    xpos   => int $match->{x},
                    width  => int $match->{w},
                    ypos   => int $match->{y},
                    height => int $match->{h},
                    type   => 'match'
                };
                $area->{margin} = int($match->{margin}) if defined $match->{margin};
                $area->{match}  = int($match->{match})  if defined $match->{match};
                #push(@{$screenshot->{matches}}, $area);
                push(@{$needlehash->{matches}}, $area);
            }
            $needlehash->{title} = $needlehash->{avg_similarity} . "%: " . $needlehash->{name};
            for my $t (@{$needleinfo->{tags}}) {
                push(@$tags, $t) unless grep(/^$t$/, @$tags);
            }
        }
    }
    if (!@needles) {
        # Failing with not a single candidate needle
        $screenshot = {
            name       => 'screenshot',
            imageurl   => $self->url_for('test_img', filename => $module_detail->{screenshot})->to_string,
            imagename  => $imgname,
            imagedir   => "",
            area       => [],
            matches    => [],
            tags       => $tags,
            json       => "",
            properties => []};
    }

    # the highest matches first
    @needles = sort { $b->{avg_similarity} <=> $a->{avg_similarity} || $a->{name} cmp $b->{name} } @needles;

    # Default values
    #  - area: matches from best candidate
    #  - tags: tags from the screenshot
    my $default_needle = {};
    my $default_name;
    if ($needles[0] && ($needles[0]->{avg_similarity} || 0) > 70) {
        $needles[0]->{selected}       = 1;
        $default_needle->{tags}       = $needles[0]->{tags};
        $default_needle->{area}       = $needles[0]->{matches};
        $default_needle->{properties} = $needles[0]->{properties};
        $screenshot->{suggested_name} = $needles[0]->{suggested_name};
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
        $screenshot->{suggested_name} = $self->_timestamp($name);
    }

    $screenshot->{title}   = 'Screenshot';
    $screenshot->{tags}    = [];
    $screenshot->{area}    = [];
    $screenshot->{matches} = [];
    unshift(@needles, $screenshot);

    # stashing the properties
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

# Adds a timestamp to a needle name or replace the already present timestamp
sub _timestamp {
    my ($self, $name) = @_;
    my $today = strftime('%Y%m%d', gmtime(time));

    if ($name =~ /(.*)-\d{8}$/) {
        return $1 . "-" . $today;
    }
    else {
        return $name . "-" . $today;
    }
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

    my $validation = $self->validation;
    $validation->required('json');
    $validation->required('imagename')->like(qr/^[^.\/][^\/]{3,}\.png$/);
    $validation->optional('imagedistri')->like(qr/^[^.\/]+$/);
    $validation->optional('imageversion')->like(qr/^[^.\/]+$/);
    $validation->required('needlename')->like(qr/^[^.\/][^\/]{3,}$/);

    if ($validation->has_error) {
        my $error = 'wrong parameters:';
        for my $k (qw(json imagename imagedistri imageversion needlename)) {
            $self->app->log->error($k . ' ' . join(' ', @{$validation->error($k)})) if $validation->has_error($k);
            $error .= ' ' . $k if $validation->has_error($k);
        }
        return $self->render(json => {error => "Error creating/updating needle: $error"});
    }

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

    my $json_data;
    eval { $json_data = $self->_json_validation($json); };
    if ($@) {
        my $message = 'Error validating needle: ' . $@;
        $self->app->log->error($message);
        return $self->render(json => {error => $message});
    }

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

    my $baseneedle = "$needledir/$needlename";
    # do not overwrite the exist needle if disallow to overwrite
    if (-e "$baseneedle.png" && !$self->param('overwrite')) {
        $success = 0;
        my $returned_data = $self->req->params->to_hash;
        $returned_data->{requires_overwrite} = 1;
        return $self->render(json => $returned_data);
    }
    unless ($imagepath eq "$baseneedle.png") {
        unless (copy($imagepath, "$baseneedle.png")) {
            $self->app->log->error("Copy $imagepath -> $baseneedle.png failed: $!");
            $success = 0;
        }
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

    if ($success) {
        $self->app->gru->enqueue('scan_needles');
        if (($self->app->config->{global}->{scm} || '') eq 'git') {
            if ($needledir && -d "$needledir/.git") {
                try {
                    $self->_commit_git($job, $needledir, $needlename);
                }
                catch {
                    $self->app->log->error($_);
                    return $self->render(json => {error => $_});
                };
            }
            else {
                return $self->render(json => {error => "$needledir is not a git repo"});
            }
        }
        $self->emit_event('openqa_needle_modify',
            {needle => "$baseneedle.png", tags => $json_data->{tags}, update => 0});
        my $info = {info => "Needle $needlename created/updated"};
        if ($job->worker_id && $job->worker->get_property('INTERACTIVE')) {
            $info->{interactive_job} = $job->id;
        }
        if ($job->can_be_duplicated) {
            $info->{restart} = $self->url_for('apiv1_restart', jobid => $job->id);
        }
        return $self->render(json => $info);
    }
    else {
        return $self->render(json => {error => "Error creating/updating needle: $!."});
    }
    # not reached
    return;
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

    my @needles;

    # load primary needle match
    if ($module_detail->{needle}) {
        my $needle = needle_info($module_detail->{needle}, $distribution, $dversion, $module_detail->{json});
        if ($needle) {    # possibly missing/broken file
            my $info = {
                name => $module_detail->{needle},
                image =>
                  $self->needle_url($distribution, $module_detail->{needle} . '.png', $dversion, $needle->{json}),
                areas   => $needle->{area},
                error   => $module_detail->{error},
                matches => []};
            calc_matches($info, $module_detail->{area});
            push(@needles, $info);
        }
    }

    # load other needle matches
    if ($module_detail->{needles}) {
        my $needlename;
        my $needleinfo;
        for my $needle (@{$module_detail->{needles}}) {
            $needlename = $needle->{name};
            $needleinfo = needle_info($needlename, $distribution, $dversion, $needle->{json});
            next unless $needleinfo;
            my $info = {
                name    => $needlename,
                image   => $self->needle_url($distribution, "$needlename.png", $dversion, $needleinfo->{json}),
                error   => $needle->{error},
                areas   => $needleinfo->{area},
                matches => []};
            calc_matches($info, $needle->{area});
            push(@needles, $info);
        }
    }

    # the highest matches first
    @needles = sort { $b->{avg_similarity} <=> $a->{avg_similarity} || $a->{name} cmp $b->{name} } @needles;

    # preselect a rather good needle
    if ($needles[0] && $needles[0]->{avg_similarity} > 70) {
        $needles[0]->{selected} = 1;
    }

    $self->stash('screenshot', $module_detail->{screenshot});
    $self->stash('tags',       $module_detail->{tags});
    $self->stash('needles',    \@needles);
    return $self->render('step/viewimg');
}

1;
# vim: set sw=4 et:
