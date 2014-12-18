# Copyright (C) 2014 SUSE Linux Products GmbH
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

package OpenQA::Controller::Step;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use File::Basename;
use File::Copy;
use Scheduler;
use POSIX qw/strftime/;
use Try::Tiny;

sub init {
    my $self = shift;

    my $testindex = $self->param('stepid');


    my $job = Scheduler::job_get($self->param('testid'));
    $self->stash('testname', $job->{'name'});
    my $testdirname = $job->{'settings'}->{'NAME'};
    my $results = test_result($testdirname);

    unless ($results) {
        $self->render_not_found;
        return 0;
    }
    $self->stash('results', $results);

    my $module = test_result_module($results->{'testmodules'}, $self->param('moduleid'));
    unless ($module) {
        $self->render_not_found;
        return 0;
    }
    $self->stash('module', $module);
    $self->stash('imglist', $module->{'details'});

    my $modinfo = get_running_modinfo($results);
    $self->stash('modinfo', $modinfo);

    my $tabmode = 'screenshot'; # Default
    if ($testindex > @{$module->{'details'}}) {
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
            $self->render_not_found;
            return 0;
        }
    }
    else {
        my $module_detail = $module->{'details'}->[$testindex-1];
        $tabmode = 'audio' if ($module_detail->{'audio'});
        $self->stash('module_detail', $module_detail);
    }
    $self->stash('tabmode', $tabmode);

    1;
}

# Helper function to generate the needle url, with an optional version
sub needle_url {
    my $self = shift;
    my $distri = shift;
    my $name = shift;
    my $version = shift;

    if (defined($version) && $version) {
        $self->url_for('needle_file', distri => $distri, name => $name)->query(version => $version);
    }
    else {
        $self->url_for('needle_file', distri => $distri, name => $name);
    }
}

# Call to viewimg or viewaudio
sub view {
    my $self = shift;
    return 0 unless $self->init();

    if ('audio' eq $self->stash('tabmode')) {
        $self->render('step/viewaudio');
    }
    else {
        $self->viewimg;
    }
}

# Needle editor
sub edit {
    my $self = shift;
    return 0 unless $self->init();

    my $module_detail = $self->stash('module_detail');
    my $imgname = $module_detail->{'screenshot'};
    my $results = $self->stash('results');
    my $job = Scheduler::job_get($self->param('testid'));
    my $testdirname = $job->{'settings'}->{'NAME'};

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
    $tags = $module_detail->{'tags'} if ($module_detail->{'tags'});
    my $screenshot;

    if ($module_detail->{'needle'}) {

        # First position: the screenshot with all the matching areas (in result)
        $screenshot = {
            'name' => 'screenshot',
            'imageurl' => $self->url_for('test_img', filename => $module_detail->{'screenshot'}),
            'imagename' => $imgname,
            'area' => [],
            'matches' => [],
            'tags' => []
        };
        for my $tag (@$tags) {
            push(@{$screenshot->{'tags'}}, $tag);
        }
        for my $area (@{$module_detail->{'area'}}) {
            push(
                @{$screenshot->{'matches'}},
                {
                    'xpos' => int $area->{'x'},
                    'width' => int $area->{'w'},
                    'ypos' => int $area->{'y'},
                    'height' => int $area->{'h'},
                    'type' => 'match'
                }
            );
        }
        # Second position: the only needle (with the same matches)
        my $needle = needle_info($module_detail->{'needle'}, $results->{'distribution'}, $results->{'version'}||'');

        $self->app->log->error(sprintf("Could not find needle: %s for %s %s",$module_detail->{'needle'},$results->{'distribution'},$results->{'version'})) if !defined $needle;

        my $matched = {
            'name' => $module_detail->{'needle'},
            'suggested_name' => $self->_timestamp($module_detail->{'needle'}),
            'imageurl' => $self->needle_url($results->{'distribution'}, $module_detail->{'needle'}.'.png',$results->{'version'}),
            'imagename' => basename($needle->{'image'}),
            'imagedistri' => $needle->{'distri'},
            'imageversion' => $needle->{'version'},
            'area' => $needle->{'area'},
            'tags' => $needle->{'tags'},
            'matches' => $screenshot->{'matches'}
        };
        calc_min_similarity($matched, $module_detail->{'area'});
        push(@needles, $matched);

        for my $t (@{$needle->{'tags'}}) {
            push(@$tags, $t) unless grep(/^$t$/, @$tags);
        }

    }
    elsif ($module_detail->{'needles'}) {

        # First position: the screenshot
        $screenshot = {
            'name' => 'screenshot',
            'imagename' => $imgname,
            'imageurl' => $self->url_for('test_img', filename => $module_detail->{'screenshot'}),
            'area' => [],
            'matches' => [],
            'tags' => []
        };
        for my $tag (@$tags) {
            push(@{$screenshot->{'tags'}}, $tag);
        }
        # Afterwards, all the candidate needles
        my $needleinfo;
        my $needlename;
        my $area;
        # For each candidate we will use theee variables:
        # $needle: needle information from result, in which 'areas' refers to the best matches
        # $needlename: read from the above
        # $needleinfo: actual definition of the needle, with the original areas
        # We also use $area for transforming the match information intro a real area
        for my $needle (@{$module_detail->{'needles'}}) {
            $needlename = $needle->{'name'};
            $needleinfo = needle_info($needlename, $results->{'distribution'}, $results->{'version'}||'');

            if( !defined $needleinfo ) {
                $self->app->log->error(sprintf("Could not parse needle: %s for %s %s",$needlename,$results->{'distribution'},$results->{'version'} || ''));

                $needleinfo->{'image'} = [];
                $needleinfo->{'tags'} = [];
                $needleinfo->{'area'} = [];
                $needleinfo->{'broken'} = 1;
            }

            push(
                @needles,
                {
                    'name' => $needlename,
                    'suggested_name' => $self->_timestamp($needlename),
                    'imageurl' => $self->needle_url($results->{'distribution'}, "$needlename.png", $results->{'version'}),
                    'imagename' => basename($needleinfo->{'image'}),
                    'imagedistri' => $needleinfo->{'distri'},
                    'imageversion' => $needleinfo->{'version'},
                    'tags' => $needleinfo->{'tags'},
                    'area' => $needleinfo->{'area'},
                    'matches' => [],
                    'broken' => $needleinfo->{'broken'}
                }
            );
            for my $match (@{$needle->{'area'}}) {
                $area = {
                    'xpos' => int $match->{'x'},
                    'width' => int $match->{'w'},
                    'ypos' => int $match->{'y'},
                    'height' => int $match->{'h'},
                    'type' => 'match'
                };
                #push(@{$screenshot->{'matches'}}, $area);
                push(@{$needles[scalar(@needles)-1]->{'matches'}}, $area);
            }
            calc_min_similarity($needles[scalar(@needles)-1], $needle->{'area'});
            for my $t (@{$needleinfo->{'tags'}}) {
                push(@$tags, $t) unless grep(/^$t$/, @$tags);
            }
        }
    }
    else {
        # Failing with not a single candidate needle
        $screenshot = {
            'name' => 'screenshot',
            'imageurl' => $self->url_for('test_img', filename => $module_detail->{'screenshot'}),
            'imagename' => $imgname,
            'area' => [],
            'matches' => [],
            'tags' => $tags
        };
    }

    # the highest matches first
    @needles =
      sort { $b->{min_similarity} cmp $a->{min_similarity} ||$a->{name} cmp $b->{name} } @needles;

    # Default values
    #  - area: matches from best candidate
    #  - tags: tags from the screenshot
    my $default_needle = {};
    my $default_name;
    if ($needles[0] && ($needles[0]->{min_similarity} || 0) > 70) {
        $needles[0]->{selected} = 1;
        $default_needle->{'tags'} = $needles[0]->{'tags'};
        $default_needle->{'area'} = $needles[0]->{'matches'};
        $screenshot->{'suggested_name'} = $needles[0]->{'suggested_name'};
    }
    else {
        $screenshot->{selected} = 1;
        $default_needle->{'tags'} = $screenshot->{'tags'};
        $default_needle->{'area'} = [];
        $screenshot->{'suggested_name'} = $self->_timestamp($self->param('moduleid'));
    }

    unshift(@needles, $screenshot);

    $self->stash('needles', \@needles);
    $self->stash('tags', $tags);
    $self->stash('default_needle', $default_needle);

    $self->render('step/edit');
}

sub src {
    my $self = shift;
    return 0 unless $self->init();

    my $results = $self->stash('results');
    my $module = $self->stash('module');

    my $testcasedir = testcasedir($results->{distribution}, $results->{version});
    my $scriptpath = "$testcasedir/$module->{'script'}";
    if(!$scriptpath || !-e $scriptpath) {
        $scriptpath||="";
        return $self->render_not_found;
    }

    my $script=file_content($scriptpath);

    $self->stash('script', $script);
    $self->stash('scriptpath', $scriptpath);
}

sub _commit_git {
    my ($self, $job, $dir, $name) = @_;
    if ($dir !~ /^\//) {
        use Cwd qw/abs_path/;
        $dir = abs_path($dir);
    }
    my @git = ('git','--git-dir', "$dir/.git",'--work-tree', $dir);
    my @files = ($dir.'/'.$name.'.json', $dir.'/'.$name.'.png');
    if (system(@git, 'add', @files) != 0) {
        die "failed to git add $name";
    }
    my @cmd = (@git, 'commit', '-q', '-m',sprintf("%s for %s", $name, $job->{'name'}),sprintf('--author=%s <%s>', $self->current_user->fullname, $self->current_user->email),@files);
    $self->app->log->debug(join(' ', @cmd));
    if (system(@cmd) != 0) {
        die "failed to git commit $name";
    }
    if (($self->app->config->{'scm git'}->{'do_push'}||'') eq 'yes') {
        if (system(@git, 'push', 'origin', 'master') != 0) {
            die "failed to git push $name";
        }
    }
}

# Adds a timestamp to a needle name or replace the already present timestamp
sub _timestamp {
    my $self = shift;
    my $name = shift;
    my $today = strftime("%Y%m%d", gmtime(time));

    if ( $name =~ /(.*)-\d{8}$/ ) {
        return $1."-".$today;
    }
    else {
        return $name."-".$today;
    }
}

sub save_needle {
    my $self = shift;
    return 0 unless $self->init();

    my $validation = $self->validation;

    $validation->required('json');
    $validation->required('imagename')->like(qr/^[^.\/][^\/]{3,}\.png$/);
    $validation->optional('imagedistri')->like(qr/^[^.\/]+$/);
    $validation->optional('imageversion')->like(qr/^[^.\/]+$/);
    $validation->required('needlename')->like(qr/^[^.\/][^\/]{3,}$/);

    if ($validation->has_error) {
        my $error = "wrong parameters";
        for my $k (qw/json imagename imagedistri imageversion needlename/) {
            $self->app->log->error($k.' '. join(' ', @{$validation->error($k)})) if $validation->has_error($k);
            $error .= ' '.$k if $validation->has_error($k);
        }
        $self->stash(error => "Error creating/updating needle: $error");
        return $self->edit;
    }

    my $results = $self->stash('results');
    my $job = Scheduler::job_get($self->param('testid'));
    my $testdirname = $job->{'settings'}->{'NAME'};
    my $json = $validation->param('json');
    my $imagename = $validation->param('imagename');
    my $imagedistri = $validation->param('imagedistri');
    my $imageversion = $validation->param('imageversion');
    my $needlename = $validation->param('needlename');
    my $needledir = needledir($results->{distribution}, $results->{version});
    my $success = 1;

    my $imagepath;
    if ($imagedistri) {
        $imagepath = join('/', needledir($imagedistri, $imageversion), $imagename);
    }
    else {
        $imagepath = join('/', $basedir, $prj, 'testresults', $testdirname, $imagename);
    }
    if (!-f $imagepath) {
        $self->stash(error => "Image $imagename could not be found!\n");
        $self->app->log->error("$imagepath is not a file");
        return $self->edit;
    }

    my $baseneedle = "$needledir/$needlename";
    unless ($imagepath eq "$baseneedle.png") {
        unless (copy($imagepath, "$baseneedle.png")) {
            $self->app->log->error("Copy $imagepath -> $baseneedle.png failed: $!");
            $success = 0;
        }
    }
    if ($success) {
        system("optipng", "-quiet", "$baseneedle.png");
        open(J, ">", "$baseneedle.json") or $success = 0;
        if ($success) {
            print J $json;
            close(J);
        }
        else {
            $self->app->log->error("Writing needle $baseneedle.json failed: $!");
        }
    }

    if ($success) {
        if ($self->app->config->{global}->{scm}||'' eq 'git') {
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
        my $sim = int($area->{'similarity'} + 0.5);
        push(
            @{$needle->{'matches'}},
            {
                'xpos' => int $area->{'x'},
                'width' => int $area->{'w'},
                'ypos' => int $area->{'y'},
                'height' => int $area->{'h'},
                'type' => $area->{'result'},
                'similarity' => $sim
            }
        );
    }
    calc_min_similarity($needle, $areas);
}

sub calc_min_similarity($$) {
    my ($needle, $areas) = @_;

    my $min_sim;

    for my $area (@$areas) {
        my $sim = int($area->{'similarity'} + 0.5);
        if (!defined $min_sim || $min_sim > $sim) {
            $min_sim = $sim;
        }
    }
    $needle->{min_similarity} = $min_sim;
}

sub viewimg {
    my $self = shift;
    my $module_detail = $self->stash('module_detail');
    my $results = $self->stash('results');

    my @needles;
    if ($module_detail->{'needle'}) {
        my $needle = needle_info($module_detail->{'needle'}, $results->{'distribution'}, $results->{'version'}||'');
        my $info = {
            'name' => $module_detail->{'needle'},
            'image' => $self->needle_url($results->{'distribution'}, $module_detail->{'needle'}.'.png', $results->{'version'}),
            'areas' => $needle->{'area'},
            'matches' => []
        };
        calc_matches($info, $module_detail->{'area'});
        push(@needles, $info);
    }
    elsif ($module_detail->{'needles'}) {
        my $needlename;
        my $needleinfo;
        for my $needle (@{$module_detail->{'needles'}}) {
            $needlename = $needle->{'name'};
            $needleinfo  = needle_info($needlename, $results->{'distribution'}, $results->{'version'}||'');
            next unless $needleinfo;
            my $info = {
                'name' => $needlename,
                'image' => $self->needle_url($results->{'distribution'}, "$needlename.png", $results->{'version'}),
                'areas' => $needleinfo->{'area'},
                'matches' => []
            };
            calc_matches($info, $needle->{'area'});
            push(@needles, $info);
        }
    }

    # the highest matches first
    @needles =
      sort { $b->{min_similarity} cmp $a->{min_similarity} ||$a->{name} cmp $b->{name} } @needles;
    # preselect a rather good needle
    if ($needles[0] && $needles[0]->{min_similarity} > 70) {
        $needles[0]->{selected} = 1;
    }

    $self->stash('screenshot', $module_detail->{'screenshot'});
    $self->stash('needles', \@needles);
    $self->stash('img_width', 1024);
    $self->stash('img_height', 768);
    $self->render('step/viewimg');
}

1;
# vim: set sw=4 et:
