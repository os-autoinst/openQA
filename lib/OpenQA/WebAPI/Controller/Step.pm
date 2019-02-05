# Copyright (C) 2014-2019 SUSE LLC
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
use Mojo::Util 'decode';
use OpenQA::Utils;
use OpenQA::Jobs::Constants;
use File::Basename;
use File::Which 'which';
use POSIX 'strftime';
use Try::Tiny;
use Mojo::JSON 'decode_json';

sub init {
    my ($self) = @_;

    my $job    = $self->app->schema->resultset('Jobs')->find($self->param('testid')) or return;
    my $module = OpenQA::Schema::Result::JobModules::job_module($job, $self->param('moduleid'));
    $self->stash(job      => $job);
    $self->stash(testname => $job->name);
    $self->stash(distri   => $job->DISTRI);
    $self->stash(version  => $job->VERSION);
    $self->stash(build    => $job->BUILD);
    $self->stash(module   => $module);

    return 1;
}

sub check_tabmode {
    my ($self) = @_;

    my $job       = $self->stash('job');
    my $module    = $self->stash('module');
    my $details   = $module->details();
    my $testindex = $self->param('stepid');
    return if ($testindex > @$details);

    my $tabmode       = 'screenshot';                 # default
    my $module_detail = $details->[$testindex - 1];
    if ($module_detail->{audio}) {
        $tabmode = 'audio';
    }
    elsif ($module_detail->{text}) {
        my $file_content = decode('UTF-8', path($job->result_dir(), $module_detail->{text})->slurp);
        $self->stash('textresult', $file_content);
        $tabmode = 'text';
    }
    $self->stash('imglist',       $details);
    $self->stash('module_detail', $module_detail);
    $self->stash('tabmode',       $tabmode);

    return 1;
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
        my $anchor     = "#step/" . $self->param('moduleid') . "/" . $self->param('stepid');
        my $target_url = $self->url_for('test', testid => $self->param('testid'));
        return $self->redirect_to($target_url . $anchor);
    }

    return $self->reply->not_found unless $self->init() && $self->check_tabmode();

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
    return $self->reply->not_found unless $self->init() && $self->check_tabmode();

    my $module_detail = $self->stash('module_detail');
    my $job           = $self->stash('job');
    my $imgname       = $module_detail->{screenshot};
    my $distribution  = $job->DISTRI;
    my $dversion      = $job->VERSION || '';

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
            my $joined_tags     = $new_needle_tags ? join(', ', @$new_needle_tags) : 'none';
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

    return $self->reply->not_found unless $self->init();

    my $job    = $self->stash('job');
    my $module = $self->stash('module');

    my $testcasedir = testcasedir($job->DISTRI, $job->VERSION);
    my $scriptpath  = "$testcasedir/" . $module->script;
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

sub save_needle_ajax {
    my ($self) = @_;
    return $self->reply->not_found unless $self->init();

    # validate parameter
    my $app        = $self->app;
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
            $app->log->error($k . ' ' . join(' ', @{$validation->error($k)})) if $validation->has_error($k);
            $error .= ' ' . $k if $validation->has_error($k);
        }
        return $self->render(json => {error => $error});
    }

    # read parameter
    my $job = find_job($self, $self->param('testid'))
      or return $self->render(json => {error => 'The specified job ID is invalid.'});
    my $job_id     = $job->id;
    my $needledir  = needledir($job->DISTRI, $job->VERSION);
    my $needlename = $validation->param('needlename');

    # check whether Minion worker are available to get a nice error message instead of an inactive job
    my $gru = $self->gru;
    if (!$gru->has_workers) {
        return $self->render(
            json => {error => 'No Minion worker available. The <code>openqa-gru</code> service is likely not running.'}
        );
    }

    # enqueue Minion job to copy the image and (if configured) run Git commands
    my %minion_args = (
        job_id       => $job_id,
        user_id      => $self->current_user->id,
        needle_json  => $validation->param('json'),
        overwrite    => $self->param('overwrite'),
        imagedir     => $self->param('imagedir') // '',
        imagedistri  => $validation->param('imagedistri'),
        imagename    => $validation->param('imagename'),
        imageversion => $validation->param('imageversion'),
        needledir    => $needledir,
        needlename   => $needlename,
    );
    my %minion_options = (
        priority => 10,
        ttl      => 60,
    );
    my $ids = $gru->enqueue(save_needle => \%minion_args, \%minion_options);
    my $minion_id;
    if (ref $ids eq 'HASH') {
        $minion_id = $ids->{minion_id};
    }
    my $minion     = $app->minion;
    my $minion_job = $minion->job($minion_id);
    if (!$minion_job) {
        return $self->render(json => {error => 'Unable to enqueue Minion job for saving needle.'});
    }

    # keep track of the Minion job and continue rendering if it has completed
    my $timer_id;
    my $check_results = sub {
        my ($loop) = @_;

        eval {
            # find the minion job
            my $minion_job = $minion->job($minion_id);
            if (!$minion_job) {
                $loop->remove($timer_id);
                return $self->render(json => {error => 'Minion job for saving needle has been removed.'});
            }
            my $info  = $minion_job->info;
            my $state = $info->{state};

            # retry on next tick if the job is still running
            return unless $state && ($state eq 'finished' || $state eq 'failed');
            $loop->remove($timer_id);

            # handle request for overwrite
            my $result = $info->{result};
            if ($result->{requires_overwrite}) {
                my $initial_request = $self->req->params->to_hash;
                $initial_request->{requires_overwrite} = 1;
                return $self->render(json => $initial_request);
            }

            # trigger needle scan and emit event on success
            if (my $json_data = $result->{json_data}) {
                $app->gru->enqueue('scan_needles');
                $app->emit_event(
                    'openqa_needle_modify',
                    {
                        needle => "$needledir/$needlename.png",
                        tags   => $json_data->{tags},
                        update => 0,
                    });
            }

            # add the URL to restart if that should be proposed to the user
            $result->{restart} = $self->url_for('apiv1_restart', jobid => $job_id) if ($result->{propose_restart});

            return $self->render(json => $result);
        };

        # ensure the timer is removed and something rendered in any case
        if ($@) {
            $loop->remove($timer_id);
            return $self->render(json => {error => 'An internal error occured.'}, status => 500);
        }
    };
    $timer_id = Mojo::IOLoop->recurring(0.5 => $check_results);
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
    my $dversion     = $job->VERSION || '';

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
