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

use strict;
use warnings;

package OpenQA::File;
use Mojo::Base 'Mojolicious::Controller';
BEGIN { $ENV{MAGICK_THREAD_LIMIT}=1; }
use Image::Magick;
use openqa;
use File::Basename;

use Data::Dump qw(pp);

use Mojolicious::Static;

sub needle {
    my $self = shift;

    my $name = $self->param('name');
    my $distri = $self->param('distri');
    my $version = $self->param('version') || '';
    if ($self->stash('format') eq 'json') {
        my $fullname = openqa::needle_info($name, $distri, $version)->{'json'};
        return $self->static->serve($self, $fullname);
    }
    else {
        my $info = openqa::needle_info($name, $distri, $version);
        return $self->static->serve($self, $info->{'image'});
    }
}

sub _set_test($) {
    my $self = shift;

    $self->{job} = Scheduler::job_get($self->param('testid'));
    return undef unless $self->{job};

    $self->{testdirname} = $self->{job}->{'settings'}->{'NAME'};
    $self->{static} = Mojolicious::Static->new;
    push @{$self->{static}->paths}, openqa::testresultdir($self->{testdirname});
    push @{$self->{static}->paths}, openqa::testresultdir($self->{testdirname} . '/ulogs');
    return 1;
}

sub test_file {
    my $self = shift;

    return $self->render_not_found unless $self->_set_test;

    return $self->serve_static_($self->param('filename'));
}

sub test_diskimage {
    my $self = shift;

    return $self->render_not_found unless $self->_set_test;

    my $diskimg = $self->param('imageid');

    my $basepath = back_log($self->{testdirname});

    return $self->render_not_found if (!-d $basepath);

    my $imgpath = "$basepath/$diskimg";
    return $self->render_not_found if (!-e $imgpath);

    # TODO: the original had gzip compression here
    #print header(-charset=>"UTF-8", -type=>"application/x-gzip", -attachment => $testname.'_'.$diskimg.'.gz', -expires=>'+24h', -max_age=>'86400', -Last_Modified=>awstandard::HTTPdate($mtime));
    return $self->serve_static_($imgpath);
}

sub test_isoimage {
    my $self = shift;

    return $self->render_not_found unless $self->_set_test;
    push @{$self->{static}->paths}, $openqa::isodir;

    return $self->serve_static_($self->{job}->{settings}->{ISO});
}

sub serve_static_($$) {
    my $self = shift;

    my $asset = shift;

    unless (ref($asset)) {
        # TODO: check for plain file name
        $asset = $self->{static}->file($asset);
    }

    return $self->render_not_found unless $asset;

    if (ref($asset) eq "Mojo::Asset::File") {
        my $filename = basename($asset->path);
        $self->res->headers->content_disposition("attatchment; filename=$filename;");
        # guess content type from extension
        if ($filename =~ m/\.([^\.]+)/) {
            my $filetype = $self->app->types->type($1);
            if ($filetype) {
                $self->res->headers->content_type($filetype);
            }
        }
    }

    $self->{static}->serve_asset($self, $asset);
    return !!$self->rendered;
}

# images are served by test_file, only thumbnails are special
sub test_thumbnail {
    my $self = shift;

    return $self->render_not_found unless $self->_set_test;

    my $asset = $self->{static}->file(".thumbs/" . $self->param('filename'));
    return $self->serve_static_($asset) if ($asset);

    # old way. TODO: remove soonish (as soon as all existant tests are created with recent os-autoinst)
    $asset = $self->{static}->file($self->param('filename'));
    return $self->render_not_found unless $asset;

    my $mem = Mojo::Asset::Memory->new;

    my $cachename = "cache_" . $asset->path;
    if(!$self->app->chi('ThumbCache')->is_valid($cachename)) {
        my $p = new Image::Magick(depth=>8);
        $p->Read($asset->path, depth=>8);
        $p->Resize( geometry => "120x120" ); # make thumbnail
        $p = $p->ImageToBlob(magick=>'PNG', depth=>8, quality=>80);
        $mem->add_chunk($p);
        $self->app->chi('ThumbCache')->set($cachename, $p, { expires_in => '30 min' });
    }
    else {
        my $p2 = $self->app->chi('ThumbCache')->get($cachename);
        $mem->add_chunk($p2);
    }

    $self->res->headers->content_type("image/png");

    return $self->serve_static_($mem);
}

1;
# vim: set sw=4 et:
