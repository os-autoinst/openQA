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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::WebAPI::Controller::File;

use strict;
use warnings;
use Mojo::Base 'Mojolicious::Controller';
BEGIN { $ENV{MAGICK_THREAD_LIMIT} = 1; }
use OpenQA::Utils;
use File::Basename;
use File::Spec;
use File::Spec::Functions 'catfile';

use Data::Dump 'pp';

use Mojolicious::Static;

sub needle {
    my $self = shift;

    # do the format splitting ourselves instead of using mojo to restrict the suffixes
    # 13.1.png would be format 1.png otherwise
    my ($name, $dummy, $format) = fileparse($self->param('name'), qw(.png .txt));
    my $distri   = $self->param('distri');
    my $version  = $self->param('version') || '';
    my $jsonfile = $self->param('jsonfile') || '';
    # make sure the directory of the file parameter is a real subdir of
    # testcasedir before applying it as needledir to prevent access
    # outside of the zoo
    if ($jsonfile
        && index(File::Spec->rel2abs($jsonfile), File::Spec->rel2abs(OpenQA::Utils::testcasedir($distri, $version)))
        != 0)
    {
        warn "$jsonfile is not in a subdir of " . OpenQA::Utils::testcasedir($distri, $version);
        return $self->render(text => "Forbidden", status => 403);
    }
    my $needle = OpenQA::Utils::needle_info($name, $distri, $version, $jsonfile);
    return $self->reply->not_found unless $needle;

    $self->{static} = Mojolicious::Static->new;
    # needledir is an absolute path from the needle database
    push @{$self->{static}->paths}, $needle->{needledir};

    # name is an URL parameter and can't contain slashes, so it should be safe
    return $self->serve_static_($name . $format);
}

sub _set_test($) {
    my $self = shift;

    $self->{job} = $self->db->resultset("Jobs")->find({'me.id' => $self->param('testid')});
    return unless $self->{job};

    $self->{testdirname} = $self->{job}->result_dir;
    return unless $self->{testdirname};
    $self->{static} = Mojolicious::Static->new;
    push @{$self->{static}->paths}, $self->{testdirname};
    push @{$self->{static}->paths}, $self->{testdirname} . "/ulogs";
    return 1;
}

sub test_file {
    my $self = shift;

    return $self->reply->not_found unless $self->_set_test;

    return $self->serve_static_($self->param('filename'));
}

sub download_asset {
    my ($self) = @_;
    # we handle this in apache
    return $self->reply->not_found;
}

sub test_asset {
    my ($self) = @_;

    my $jobid = $self->param('testid');
    my %cond = ('me.id' => $jobid);
    if ($self->param('assetid')) { $cond{'asset.id'} = $self->param('assetid') }
    elsif ($self->param('assettype') and $self->param('assetname')) {
        $cond{name} = $self->param('assetname');
        $cond{type} = $self->param('assettype');
    }
    else { return $self->render(text => 'Missing or wrong parameters provided', status => 400) }

    my %asset;
    my $attrs = {join => {jobs_assets => 'asset'}, +select => [qw(asset.name asset.type)], +as => [qw(name type)]};
    my $res = $self->db->resultset('Jobs')->search(\%cond, $attrs);
    if ($res and $res->first) { %asset = $res->first->get_columns }
    else                      { return $self->reply->not_found }

    # find the asset path
    my $path = locate_asset($asset{type}, $asset{name}, relative => 1);
    $path = catfile($path, $self->param('subpath')) if $self->param('subpath');
    return $self->render(text => 'invalid character in path', status => 400)
      if ($path =~ /\/\.\./ || $path =~ /\.\.\//);

    # map to URL - mojo will canonalize
    $path = $self->url_for('download_asset', assetpath => $path);
    $self->app->log->debug("redirect to $path");
    return $self->redirect_to($path);
}


sub test_isoimage {
    my $self = shift;

    return $self->reply->not_found unless $self->_set_test;
    push @{$self->{static}->paths}, $OpenQA::Utils::isodir;

    return $self->serve_static_($self->{job}->settings_hash->{ISO});
}

sub serve_static_ {
    my ($self, $asset) = @_;

    $self->app->log->debug("looking for " . pp($asset) . " in " . pp($self->{static}->paths));
    if ($asset && !ref($asset)) {
        # TODO: check for plain file name
        $asset = $self->{static}->file($asset);
    }

    $self->app->log->debug("found " . pp($asset));

    return $self->reply->not_found unless $asset;

    if (ref($asset) eq "Mojo::Asset::File") {
        my $filename = basename($asset->path);
        # guess content type from extension
        if ($filename =~ m/\.([^\.]+)$/) {
            my $ext      = $1;
            my $filetype = $self->app->types->type($ext);
            if ($filetype) {
                $self->res->headers->content_type($filetype);
            }
            if ($ext eq 'iso') {
                # force saveAs
                $self->res->headers->content_disposition("attatchment; filename=$filename;");
            }
        }
        else {
            $self->res->headers->content_type("application/octet-stream");
        }
    }

    $self->{static}->serve_asset($self, $asset);
    return !!$self->rendered;
}

# images are served by test_file, only thumbnails are special
sub test_thumbnail {
    my $self = shift;

    return $self->reply->not_found unless $self->_set_test;

    my $asset = $self->{static}->file(".thumbs/" . $self->param('filename'));
    return $self->serve_static_($asset);
}

# this is the agnostic route to images - usually served by apache directly
sub thumb_image {
    my ($self) = @_;

    $self->{static} = Mojolicious::Static->new;
    push @{$self->{static}->paths}, $OpenQA::Utils::imagesdir;

    # name is an URL parameter and can't contain slashes, so it should be safe
    my $dir = $self->param('md5_dirname') || ($self->param('md5_1') . '/' . $self->param('md5_2'));
    return $self->serve_static_("$dir/.thumbs/" . $self->param('md5_basename'));
}

1;
# vim: set sw=4 et:
