# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Step;
use Mojo::Base 'Mojolicious::Controller';

use Cwd 'realpath';
use Mojo::File 'path';
use Mojo::URL;
use Mojo::Util 'decode';
use OpenQA::Utils qw(ensure_timestamp_appended find_bug_number locate_needle needledir testcasedir);
use OpenQA::Jobs::Constants;
use File::Basename;
use File::Which 'which';
use POSIX 'strftime';
use Mojo::JSON 'decode_json';

sub _init {
    my ($self) = @_;

    return 0 unless my $job = $self->app->schema->resultset('Jobs')->find($self->param('testid'));
    my $module = $job->modules->search({name => $self->param('moduleid')})->first;
    $self->stash(job => $job);
    $self->stash(testname => $job->name);
    $self->stash(distri => $job->DISTRI);
    $self->stash(version => $job->VERSION);
    $self->stash(build => $job->BUILD);
    $self->stash(module => $module);

    return 1;
}

sub check_tabmode {
    my ($self) = @_;

    my $job = $self->stash('job');
    my $module = $self->stash('module');
    my $details = $module->results->{details};
    my $testindex = $self->param('stepid');
    return if ($testindex > @$details);

    my $tabmode = 'screenshot';    # default
    my $module_detail = $details->[$testindex - 1];
    if ($module_detail->{audio}) {
        $tabmode = 'audio';
    }
    elsif ($module_detail->{text}) {
        $self->stash('textresult', $module_detail->{text_data});
        $tabmode = 'text';
    }
    $self->stash('imglist', $details);
    $self->stash('module_detail', $module_detail);
    $self->stash('tabmode', $tabmode);

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
        my $anchor = "#step/" . $self->param('moduleid') . "/" . $self->param('stepid');
        my $target_url = $self->url_for('test', testid => $self->param('testid'));
        return $self->redirect_to($target_url . $anchor);
    }

    return $self->reply->not_found unless $self->_init && $self->check_tabmode();

    my $tabmode = $self->stash('tabmode');
    return $self->render('step/viewaudio') if $tabmode eq 'audio';
    return $self->render('step/viewtext') if $tabmode eq 'text';
    $self->viewimg;
}

# Needle editor
sub edit {
    my ($self) = @_;
    return $self->reply->not_found unless $self->_init && $self->check_tabmode();

    my $module_detail = $self->stash('module_detail');
    my $job = $self->stash('job');
    my $imgname = $module_detail->{screenshot};
    my $distri = $job->DISTRI;
    my $dversion = $job->VERSION || '';
    my $needle_dir = $job->needle_dir;
    my $app = $self->app;
    my $needles_rs = $app->schema->resultset('Needles');

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
        tags => $tags,
        distri => $distri,
        version => $dversion,
        image_name => $imgname,
    );

    if (my $needle_name = $module_detail->{needle}) {
        # First position: the screenshot with all the matching areas (in result)
        $screenshot = $self->_new_screenshot($tags, $imgname, $module_detail->{area});

        # Second position: the only needle (with the same matches)
        my $needle_info
          = $self->_extended_needle_info($needle_dir, $needle_name, \%basic_needle_data, $module_detail->{json},
            0, \@error_messages);
        if ($needle_info) {
            $needle_info->{matches} = $screenshot->{matches};
            push(@needles, $needle_info);
        }
    }
    if (my $module_detail_needles = $module_detail->{needles}) {
        # First position: the screenshot
        $screenshot = $self->_new_screenshot($tags, $imgname);

        # Afterwards: all the candidate needles
        # $needle contains information from result, in which 'areas' refers to the best matches.
        # We also use $area for transforming the match information into a real area
        for my $needle (@$module_detail_needles) {
            my $needle_info = $self->_extended_needle_info(
                $needle_dir, $needle->{name}, \%basic_needle_data,
                $needle->{json}, $needle->{error}, \@error_messages
            ) || next;
            my $matches = $needle_info->{matches};
            for my $match (@{$needle->{area}}) {
                my %area = (
                    xpos => int $match->{x},
                    width => int $match->{w},
                    ypos => int $match->{y},
                    height => int $match->{h},
                    type => 'match',
                );
                $area{margin} = int($match->{margin}) if defined $match->{margin};
                $area{match} = int($match->{match}) if defined $match->{match};
                $area{click_point} = $match->{click_point} if defined $match->{click_point};
                push(@$matches, \%area);
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
        my $new_needles = $needles_rs->new_needles_since($job->t_started, $tags, 5);
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
              = $self->_extended_needle_info($needle_dir, $new_needle->name, \%basic_needle_data, $new_needle->path,
                undef, \@error_messages)
              || next;
            $needle_info->{title} = 'new: ' . $needle_info->{title};
            push(@needles, $needle_info);
        }
    }

    # set default values
    #  - area: matches from best candidate
    #  - tags: tags from the screenshot
    my $default_needle = {};
    my $first_needle = $needles[0];
    if ($first_needle && ($first_needle->{avg_similarity} || 0) > 70) {
        $first_needle->{selected} = 1;
        $default_needle->{tags} = $first_needle->{tags};
        $default_needle->{area} = $first_needle->{matches};
        $default_needle->{properties} = $first_needle->{properties};
        $screenshot->{suggested_name} = $first_needle->{suggested_name};
    }
    else {
        $screenshot->{selected} = 1;
        $default_needle->{tags} = $screenshot->{tags};
        $default_needle->{area} = [];
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

    $self->stash(
        {
            needles => \@needles,
            tags => $tags,
            default_needle => $default_needle,
            error_messages => \@error_messages,
            git_enabled => ($app->config->{global}->{scm} // '') eq 'git',
        });
    $self->render('step/edit');
}

sub _new_screenshot {
    my ($self, $tags, $image_name, $matches) = @_;

    my @matches;
    my %screenshot = (
        name => 'screenshot',
        title => 'Screenshot',
        imagename => $image_name,
        imagedir => '',
        imageurl => $self->url_for('test_img', filename => $image_name)->to_string(),
        area => [],
        matches => \@matches,
        properties => [],
        json => '',
        tags => $tags,
    );
    return \%screenshot unless $matches;

    for my $area (@$matches) {
        my %match = (
            xpos => int $area->{x},
            ypos => int $area->{y},
            width => int $area->{w},
            height => int $area->{h},
            type => 'match',
        );
        if (my $click_point = $area->{click_point}) {
            $match{click_point} = $click_point;
        }
        push(@matches, \%match);
    }
    return \%screenshot;
}

sub _basic_needle_info {
    my ($self, $name, $distri, $version, $file_name, $needles_dir) = @_;

    $file_name //= "$name.json";
    $file_name = locate_needle($file_name, $needles_dir) if !-f $file_name;
    return (undef, 'File not found') unless defined $file_name;

    my $needle;
    eval { $needle = decode_json(Mojo::File->new($file_name)->slurp) };
    return (undef, $@) if $@;

    my $png_fname = basename($file_name, '.json') . '.png';
    my $pngfile = File::Spec->catpath('', $needles_dir, $png_fname);

    $needle->{needledir} = $needles_dir;
    $needle->{image} = $pngfile;
    $needle->{json} = $file_name;
    $needle->{name} = $name;
    $needle->{distri} = $distri;
    $needle->{version} = $version;

    # Skip code to support compatibility if HASH-workaround properties already present
    return ($needle, undef) unless $needle->{properties};

    # Transform string-workaround-properties into HASH-workaround-properties
    $needle->{properties}
      = [map { ref($_) eq "HASH" ? $_ : {name => $_, value => find_bug_number($name)} } @{$needle->{properties}}];

    return ($needle, undef);
}

sub _extended_needle_info {
    my ($self, $needle_dir, $needle_name, $basic_needle_data, $file_name, $error, $error_messages) = @_;

    my $overall_list_of_tags = $basic_needle_data->{tags};
    my $distri = $basic_needle_data->{distri};
    my $version = $basic_needle_data->{version};
    my ($needle_info, $err) = $self->_basic_needle_info($needle_name, $distri, $version, $file_name, $needle_dir);
    unless (defined $needle_info) {
        push(@$error_messages, "Could not parse needle $needle_name for $distri $version: $err");
        return undef;
    }

    $needle_info->{title} = $needle_name;
    $needle_info->{suggested_name} = ensure_timestamp_appended($needle_name);
    $needle_info->{imageurl}
      = $self->needle_url($distri, $needle_name . '.png', $version, $needle_info->{json})->to_string();
    $needle_info->{imagename} = basename($needle_info->{image});
    $needle_info->{imagedir} = dirname($needle_info->{image});
    $needle_info->{imagedistri} = $distri;
    $needle_info->{imageversion} = $version;
    $needle_info->{tags} //= [];
    $needle_info->{matches} //= [];
    $needle_info->{properties} //= [];
    $needle_info->{json} //= '';

    $error //= $needle_info->{error};
    if (defined $error) {
        $needle_info->{avg_similarity} = map_error_to_avg($error);
        $needle_info->{title} = $needle_info->{avg_similarity} . '%: ' . $needle_name;
    }
    for my $tag (@{$needle_info->{tags}}) {
        push(@$overall_list_of_tags, $tag) unless grep(/^$tag$/, @$overall_list_of_tags);
    }
    return $needle_info;
}

sub src {
    my ($self) = @_;
    return $self->reply->not_found unless $self->_init;

    my $job = $self->stash('job');
    my $module = $self->stash('module');

    if (my $casedir = $job->settings->single({key => 'CASEDIR'})) {
        my $casedir_url = Mojo::URL->new($casedir->value);
        # if CASEDIR points to a remote location let's assume it is a git repo
        # that we can reference like gitlab/github
        last unless $casedir_url->scheme;
        my $refspec = $casedir_url->fragment;
        # try to read vars.json from resultdir and replace branch by actual git hash if possible
        eval {
            my $vars_json = Mojo::File->new($job->result_dir(), 'vars.json')->slurp;
            my $vars = decode_json($vars_json);
            $refspec = $vars->{TEST_GIT_HASH};
        };
        my $module_path = '/blob/' . $refspec . '/' . $module->script;
        # github treats '.git' as optional extension which needs to be stripped
        $casedir_url->path($casedir_url->path =~ s/\.git//r . $module_path);
        $casedir_url->fragment('');
        return $self->redirect_to($casedir_url);
    }
    my $testcasedir = testcasedir($job->DISTRI, $job->VERSION);
    my $scriptpath = "$testcasedir/" . $module->script;
    return $self->reply->not_found unless $scriptpath && -e $scriptpath;
    my $script_h = path($scriptpath)->open('<:encoding(UTF-8)');
    return $self->reply->not_found unless defined $script_h;
    my @script_content = <$script_h>;
    $self->render(script => "@script_content", scriptpath => $scriptpath);
}

sub save_needle_ajax {
    my ($self) = @_;
    return $self->reply->not_found unless $self->_init;

    # validate parameter
    my $app = $self->app;
    my $validation = $self->validation;
    $validation->required('json');
    $validation->required('imagename')->like(qr/^[^.\/][^\/]{3,}\.png$/);
    $validation->required('needlename')->like(qr/^[^.\/][^\/]{3,}$/);
    $validation->optional('imagedistri')->like(qr/^[^.\/]*$/);
    $validation->optional('imageversion')->like(qr/^[^\/]*$/);
    $validation->optional('commit_message');
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    # read parameter
    my $job = $self->find_job_or_render_not_found($self->param('testid')) or return;
    my $job_id = $job->id;
    my $needledir = needledir($job->DISTRI, $job->VERSION);
    my $needlename = $validation->param('needlename');

    $self->gru->enqueue_and_keep_track(
        task_name => 'save_needle',
        task_description => 'saving needles',
        task_args => {
            job_id => $job_id,
            user_id => $self->current_user->id,
            needle_json => $validation->param('json'),
            overwrite => $self->param('overwrite'),
            imagedir => $self->param('imagedir') // '',
            imagedistri => $validation->param('imagedistri'),
            imagename => $validation->param('imagename'),
            imageversion => $validation->param('imageversion'),
            needledir => $needledir,
            needlename => $needlename,
            commit_message => $validation->param('commit_message'),
        }
    )->then(
        sub {
            my ($result) = @_;

            # handle request for overwrite
            if ($result->{requires_overwrite}) {
                my $initial_request = $self->req->params->to_hash;
                $initial_request->{requires_overwrite} = 1;
                return $self->render(json => $initial_request);
            }

            # trigger needle scan and emit event on success
            if (my $json_data = $result->{json_data}) {
                $app->gru->enqueue('scan_needles');
                $app->emit_event(
                    openqa_needle_modify => {
                        needle => "$needledir/$needlename.png",
                        tags => $json_data->{tags},
                        update => 0,
                    });
            }

            # add the URL to restart if that should be proposed to the user
            $result->{restart} = $self->url_for('apiv1_restart', jobid => $job_id) if ($result->{propose_restart});

            $self->render(json => $result);
        }
    )->catch(
        sub {
            $self->reply->gru_result(@_);
        });
}

sub map_error_to_avg {
    my ($error) = @_;

    return int((1 - sqrt($error // 0)) * 100 + 0.5);
}

sub calc_matches {
    my ($needle, $areas) = @_;

    my $matches = $needle->{matches};
    for my $area (@$areas) {
        my %match = (
            xpos => int $area->{x},
            ypos => int $area->{y},
            width => int $area->{w},
            height => int $area->{h},
            type => $area->{result},
            similarity => int($area->{similarity} + 0.5),
        );
        if (my $click_point = $area->{click_point}) {
            $match{click_point} = $click_point;
        }
        push(@$matches, \%match);
    }
    $needle->{avg_similarity} //= map_error_to_avg($needle->{error});
    return;
}

sub viewimg {
    my $self = shift;
    my $module_detail = $self->stash('module_detail');
    my $job = $self->stash('job');
    return $self->reply->not_found unless $job;
    my $distri = $job->DISTRI;
    my $dversion = $job->VERSION || '';
    my $needle_dir = $job->needle_dir;
    my $real_needle_dir = realpath($needle_dir) // $needle_dir;
    my $needles_rs = $self->app->schema->resultset('Needles');

    # initialize hash to store needle lists by tags
    my %needles_by_tag;
    for my $tag (@{$module_detail->{tags}}) {
        $needles_by_tag{$tag} = [];
    }

    my $append_needle_info = sub {
        my ($tags, $needle_info) = @_;

        # add timestamps and URLs from database
        $self->populate_hash_with_needle_timestamps_and_urls(
            $needles_rs->find_needle($real_needle_dir, "$needle_info->{name}.json"), $needle_info);

        # handle case when the needle has (for some reason) no tags
        if (!$tags) {
            push(@{$needles_by_tag{'tags unknown'} //= []}, $needle_info);
            return undef;
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
        my ($needleinfo) = $self->_basic_needle_info($needle, $distri, $dversion, $module_detail->{json}, $needle_dir);
        if ($needleinfo) {
            my $info = {
                name => $needle,
                needledir => $needleinfo->{needledir},
                image => $self->needle_url($distri, $needle . '.png', $dversion, $needleinfo->{json}),
                areas => $needleinfo->{area},
                error => $module_detail->{error},
                matches => [],
                primary_match => 1,
                selected => 1,
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
            my ($needleinfo) = $self->_basic_needle_info($needlename, $distri, $dversion, $needle->{json}, $needle_dir);
            next unless $needleinfo;
            my $info = {
                name => $needlename,
                needledir => $needleinfo->{needledir},
                image => $self->needle_url($distri, "$needlename.png", $dversion, $needleinfo->{json}),
                error => $needle->{error},
                areas => $needleinfo->{area},
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

    # render error message if there's nothing to show
    my $screenshot = $module_detail->{screenshot};
    if (!$screenshot && !%needles_by_tag) {
        $self->stash(textresult => 'Seems like os-autoinst has produced a result which openQA can not display.');
        return $self->render('step/viewtext');
    }
    my %stash = (
        screenshot => $screenshot,
        default_label => $primary_match ? $primary_match->{label} : 'Screenshot',
        needles_by_tag => \%needles_by_tag,
        tag_count => scalar %needles_by_tag,
        video_file_name => undef,
        frametime => 0,
    );
    my $videos = $job->video_file_paths;
    my $frametime = $module_detail->{frametime};
    if ($videos->size) {
        $stash{video_file_name} = $videos->first->basename;
        $stash{frametime} = ref $frametime eq 'ARRAY' ? $frametime : 0;
    }
    $self->stash(\%stash);
    return $self->render('step/viewimg');
}

1;
