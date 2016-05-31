# Copyright (C) 2014,2015 SUSE LLC
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
use OpenQA::Utils;
use File::Basename;
use File::Copy;
use File::Which qw(which);
use POSIX qw/strftime/;
use Try::Tiny;
use JSON;

sub init {
    my $self = shift;

    my $testindex = $self->param('stepid');
    my $job       = $self->app->schema->resultset('Jobs')->find($self->param('testid'));

    return $self->reply->not_found unless $job;
    $self->stash(testname => $job->settings_hash->{NAME});
    $self->stash(distri   => $job->settings_hash->{DISTRI});
    $self->stash(version  => $job->settings_hash->{VERSION});
    $self->stash(build    => $job->settings_hash->{BUILD});

    my $module = OpenQA::Schema::Result::JobModules::job_module($job, $self->param('moduleid'));
    my $details = $module->details();
    $self->stash('job',     $job);
    $self->stash('module',  $module);
    $self->stash('imglist', $details);

    $self->stash('modinfo', $job->running_modinfo());

    my $tabmode = 'screenshot';    # Default
    if ($testindex > @$details) {
        # This means that the module have no details at all
        if ($testindex == 1) {
            if ($self->stash('action') eq 'src') {
                $tabmode = 'onlysrc';
            }
            else {
                $self->redirect_to('src_step');
                return 0;
            }
            # In this case there are details, we simply run out of range
        }
        else {
            $self->reply->not_found;
            return 0;
        }
    }
    else {
        my $module_detail = $details->[$testindex - 1];
        if ($module_detail->{audio}) {
            $tabmode = 'audio';
        }
        elsif ($module_detail->{text}) {
            $self->stash('textresult', file_content(join('/', $job->result_dir(), $module_detail->{text}), "UTF-8"));
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
            $self->url_for('needle_file', distri => $distri, name => $name)->query(version => $version, jsonfile => $jsonfile);
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
    return 0 unless $self->init();

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
    my ($self, $ow_overwrite, $ow_json, $ow_imagename, $ow_imagedistri, $ow_imageversion, $ow_needlename) = @_;
    return 0 unless $self->init();

    my $module_detail = $self->stash('module_detail');
    my $imgname       = $module_detail->{screenshot};
    my $job           = $self->app->schema->resultset('Jobs')->find($self->param('testid'));
    return $self->reply->not_found unless $job;
    my $distribution = $job->settings_hash->{DISTRI};
    my $dversion = $job->settings_hash->{VERSION} || '';

    # Each object in $needles will contain the name, both the url and the local path
    # of the image and 2 lists of areas: 'area' and 'matches'.
    # The former refers to the original definitions and the later shows the position
    # found (best try) in the actual screenshot.
    # The first element of the needles array is the screenshot itself, with an empty
    # 'areas' (there is no needle associated to the screenshot) and with all matching
    # areas in 'matches'.
    my @needles;
    # All tags (from all needles)
    my $tags = [];
    $tags = $module_detail->{tags} if ($module_detail->{tags});
    my $screenshot;
    my $overwrite = 'no';
    $overwrite = $ow_overwrite if $ow_overwrite;
    $imgname   = $ow_imagename if $overwrite eq 'yes';

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

        $self->app->log->error(sprintf("Could not find needle: %s for %s %s", $module_detail->{needle}, $distribution, $dversion)) if !defined $needle;

        my $matched = {
            name           => $module_detail->{needle},
            suggested_name => $self->_timestamp($module_detail->{needle}),
            imageurl       => $self->needle_url($distribution, $module_detail->{needle} . '.png', $dversion, $needle->{json})->to_string,
            imagename      => basename($needle->{image}),
            imagedir       => dirname($needle->{image}),
            imagedistri    => $needle->{distri},
            imageversion   => $needle->{version},
            area           => $needle->{area},
            tags           => $needle->{tags},
            json       => $needle->{json}       || "",
            properties => $needle->{properties} || [],
            matches    => $screenshot->{matches}};
        calc_min_similarity($matched, $module_detail->{area});
        $matched->{title} = $matched->{min_similarity} . "%: " . $matched->{name};
        push(@needles, $matched);

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
                $self->app->log->error(sprintf("Could not parse needle: %s for %s %s", $needlename, $distribution, $dversion || ''));

                $needleinfo->{image}  = [];
                $needleinfo->{tags}   = [];
                $needleinfo->{area}   = [];
                $needleinfo->{broken} = 1;
            }

            my $needlehash = {
                name           => $needlename,
                title          => $needlename,
                suggested_name => $self->_timestamp($needlename),
                imageurl       => $self->needle_url($distribution, "$needlename.png", $dversion, $needleinfo->{json})->to_string,
                imagename      => basename($needleinfo->{image}),
                imagedir       => dirname($needleinfo->{image}),
                imagedistri    => $needleinfo->{distri},
                imageversion   => $needleinfo->{version},
                tags           => $needleinfo->{tags},
                area           => $needleinfo->{area},
                json       => $needleinfo->{json}       || "",
                properties => $needleinfo->{properties} || [],
                matches    => [],
                broken     => $needleinfo->{broken}};
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
            calc_min_similarity($needlehash, $needle->{area});
            $needlehash->{title} = $needlehash->{min_similarity} . "%: " . $needlehash->{name};
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
    @needles = sort { $b->{min_similarity} <=> $a->{min_similarity} || $a->{name} cmp $b->{name} } @needles;

    # Default values
    #  - area: matches from best candidate
    #  - tags: tags from the screenshot
    my $default_needle = {};
    my $default_name;
    $screenshot->{overwrite} = $overwrite;
    if ($overwrite eq 'yes') {
        # decode original json to perl
        my $decode_json;
        my $ow_tags       = [];
        my $ow_area       = [];
        my $ow_properties = [];
        $decode_json   = decode_json($ow_json);
        $ow_area       = $decode_json->{area};
        $ow_tags       = $decode_json->{tags};
        $ow_properties = $decode_json->{properties};
        # replaced tags
        $tags                         = $ow_tags;
        $screenshot->{selected}       = 1;
        $default_needle->{tags}       = $ow_tags;
        $default_needle->{area}       = $ow_area;
        $default_needle->{properties} = $ow_properties;
        $screenshot->{tags}           = $ow_tags;
        $screenshot->{area}           = $ow_area;
        $screenshot->{properties}     = $ow_properties;
        $screenshot->{suggested_name} = $ow_needlename;
        $screenshot->{imagedistri}    = $ow_imagedistri;
        $screenshot->{imageversion}   = $ow_imageversion;
    }
    elsif ($needles[0] && ($needles[0]->{min_similarity} || 0) > 70) {
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
    use Data::Dumper;
    print Dumper(\@needles);
    $self->stash('needles',        \@needles);
    $self->stash('tags',           $tags);
    $self->stash('properties',     $properties);
    $self->stash('default_needle', $default_needle);

    $self->render('step/edit');
}

sub src {
    my ($self) = @_;
    return 0 unless $self->init();

    my $job    = $self->stash('job');
    my $module = $self->stash('module');
    return $self->reply->not_found unless ($job && $module);

    my $testcasedir = testcasedir($job->settings_hash->{DISTRI}, $job->settings_hash->{VERSION});
    my $scriptpath = "$testcasedir/" . $module->script;
    if (!$scriptpath || !-e $scriptpath) {
        $scriptpath ||= "";
        return $self->reply->not_found;
    }

    my $script = file_content($scriptpath, "UTF-8");

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

sub save_needle {
    my ($self) = @_;
    return 0 unless $self->init();

    my $validation = $self->validation;

    $validation->required('json');
    $validation->required('imagename')->like(qr/^[^.\/][^\/]{3,}\.png$/);
    $validation->optional('imagedistri')->like(qr/^[^.\/]+$/);
    $validation->optional('imageversion')->like(qr/^[^.\/]+$/);
    $validation->required('needlename')->like(qr/^[^.\/][^\/]{3,}$/);
    $validation->required('overwrite')->in(qw(yes no));

    if ($validation->has_error) {
        my $error = 'wrong parameters';
        for my $k (qw/json imagename imagedistri imageversion needlename overwrite/) {
            $self->app->log->error($k . ' ' . join(' ', @{$validation->error($k)})) if $validation->has_error($k);
            $error .= ' ' . $k if $validation->has_error($k);
        }
        $self->stash(error => "Error creating/updating needle: $error");
        return $self->edit;
    }

    my $job          = $self->app->schema->resultset("Jobs")->find($self->param('testid'));
    my $settings     = $job->settings_hash;
    my $distribution = $settings->{DISTRI};
    my $dversion     = $settings->{VERSION} || '';
    my $json         = $validation->param('json');
    my $imagename    = $validation->param('imagename');
    my $imagedistri  = $validation->param('imagedistri');
    my $imageversion = $validation->param('imageversion');
    my $imagedir     = $self->param('imagedir') || "";
    my $needlename   = $validation->param('needlename');
    my $overwrite    = $validation->param('overwrite');
    my $needledir    = needledir($job->settings_hash->{DISTRI}, $job->settings_hash->{VERSION});

    my $json_data;
    eval { $json_data = $self->_json_validation($json); };
    if ($@) {
        my $message = 'Error validating needle: ' . $@;
        $self->app->log->error($message);
        $self->stash(error => "$message\n");
        return $self->edit;
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
        $self->stash(error => "Image $imagename could not be found!\n");
        $self->app->log->error("$imagepath is not a file");
        return $self->edit;
    }

    my $baseneedle = "$needledir/$needlename";
    # do not overwrite the exist needle if disallow to overwrite
    if (-e "$baseneedle.png" && $overwrite eq 'no') {
        $self->stash(warn_overwrite => "Same needle name file already exists! Overwrite it?");
        $success   = 0;
        $overwrite = 'yes';
        return $self->edit($overwrite, $json, $imagename, $imagedistri, $imageversion, $needlename);
    }
    unless ($imagepath eq "$baseneedle.png") {
        unless (copy($imagepath, "$baseneedle.png")) {
            $self->app->log->error("Copy $imagepath -> $baseneedle.png failed: $!");
            $success = 0;
        }
    }
    if ($success) {
        if (which('optipng')) {
            system("optipng", "-quiet", "$baseneedle.png");
        }
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
                    $self->stash(error => $_);
                };
            }
            else {
                $self->stash(error => "$needledir is not a git repo");
            }
        }
        $self->emit_event('openqa_needle_modify', {needle => "$baseneedle.png", tags => $json_data->{tags}, update => $overwrite});
        $self->stash(info => "Needle $needlename created/updated.");
    }
    else {
        $self->stash(error => "Error creating/updating needle: $!.");
    }
    return $self->edit;
}

sub calc_matches($$) {
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
    return calc_min_similarity($needle, $areas);
}

sub calc_min_similarity($$) {
    my ($needle, $areas) = @_;

    my $min_sim;

    for my $area (@$areas) {
        my $sim = int($area->{similarity} + 0.5);
        if (!defined $min_sim || $min_sim > $sim) {
            $min_sim = $sim;
        }
    }
    return $needle->{min_similarity} = $min_sim;
}

sub viewimg {
    my $self          = shift;
    my $module_detail = $self->stash('module_detail');
    my $job           = $self->stash('job');
    return $self->reply->not_found unless $job;
    my $distribution = $job->settings_hash->{DISTRI};
    my $dversion = $job->settings_hash->{VERSION} || '';

    my @needles;
    if ($module_detail->{needle}) {
        my $needle = needle_info($module_detail->{needle}, $distribution, $dversion, $module_detail->{json});
        if ($needle) {    # possibly missing/broken file
            my $info = {
                name    => $module_detail->{needle},
                image   => $self->needle_url($distribution, $module_detail->{needle} . '.png', $dversion, $needle->{json}),
                areas   => $needle->{area},
                matches => []};
            calc_matches($info, $module_detail->{area});
            push(@needles, $info);
        }
    }
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
                areas   => $needleinfo->{area},
                matches => []};
            calc_matches($info, $needle->{area});
            push(@needles, $info);
        }
    }

    # the highest matches first
    @needles = sort { $b->{min_similarity} <=> $a->{min_similarity} || $a->{name} cmp $b->{name} } @needles;

    # preselect a rather good needle
    if ($needles[0] && $needles[0]->{min_similarity} > 70) {
        $needles[0]->{selected} = 1;
    }

    $self->stash('screenshot', $module_detail->{screenshot});
    $self->stash('needles',    \@needles);
    $self->stash('img_width',  1024);
    $self->stash('img_height', 768);
    return $self->render('step/viewimg');
}

1;
# vim: set sw=4 et:
