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

package OpenQA::File;
use Mojo::Base 'Mojolicious::Controller';
BEGIN { $ENV{MAGICK_THREAD_LIMIT}=1; }
use Image::Magick;
use openqa;

sub needle {
    my $self = shift;

    my $name = $self->param('name');
    $name =~ s/\.([^.]+)$//; # Remove file extension
    $self->stash('format', $1);
    my $distri = $self->param('distri');
    my $version = $self->param('version') || '';
    if ($self->stash('format') eq 'json') {
        my $fullname = openqa::needle_info($name, $distri, $version)->{'json'};
        $self->_serve_file($fullname);
    }
    else {
        my $info = openqa::needle_info($name, $distri, $version);
        $self->_serve_file($info->{'image'});
    }
}

sub test_logfile {
    my $self = shift;

    my $name = $self->param('filename');
    my $job = Scheduler::job_get($self->param('testid'));
    my $testdirname = $job->{'settings'}->{'NAME'};

    my $fullname = openqa::testresultdir($testdirname).'/ulogs/'.$name;
    $fullname .= '.'.$self->stash('format') if $self->stash('format');

    return $self->_serve_file($fullname);
}

sub test_file {
    my $self = shift;

    my $name = $self->param('filename');
    my $job = Scheduler::job_get($self->param('testid'));
    my $testdirname = $job->{'settings'}->{'NAME'};

    my $fullname = openqa::testresultdir($testdirname).'/'.$name;
    $fullname .= '.'.$self->stash('format') if $self->stash('format');

    return $self->_serve_file($fullname);
}

sub test_diskimage {
    my $self = shift;
    my $job = Scheduler::job_get($self->param('testid'));
    my $testdirname = $job->{'settings'}->{'NAME'};
    my $diskimg = $self->param('imageid');

    my $basepath = back_log($testdirname);

    return $self->render_not_found if (!-d $basepath);

    my $imgpath = "$basepath/$diskimg";
    return $self->render_not_found if (!-e $imgpath);

    # TODO: the original had gzip compression here
    #print header(-charset=>"UTF-8", -type=>"application/x-gzip", -attachment => $testname.'_'.$diskimg.'.gz', -expires=>'+24h', -max_age=>'86400', -Last_Modified=>awstandard::HTTPdate($mtime));
    $self->_serve_file(
        $imgpath);
}

sub isoimage {
    my $self = shift;
    my $name = $self->param('filename');
    my $job = Scheduler::job_get($self->param('testid'));

    my $filename = $job ? $job->{'settings'}->{'ISO'} : $name;
    return $self->render_not_found if !$filename;

    my $iso_file = $openqa::isodir.'/'.$filename;

    if (!-f $iso_file) {
        $self->app->log->warn("Could not find $iso_file");
        return $self->render_not_found;
    }

    # TODO: gzip compression
    #print header(-charset=>"UTF-8", -type=>"application/x-gzip", -attachment => $testname.'_'.$diskimg.'.gz', -expires=>'+24h', -max_age=>'86400', -Last_Modified=>awstandard::HTTPdate($mtime));

    return $self->render_file(
        'filepath' => $iso_file,
        'format' => 'iso'
    );
}

# serve file specified with absolute path name. No sanity checks
# done here. Take care!
sub _serve_file {
    my $self = shift;
    my $fullname = shift;

    return $self->render_not_found if (!-e $fullname);

    # Last modified
    my $mtime = (stat _)[9];
    my $res = $self->res;
    $res->code(200)->headers->last_modified(Mojo::Date->new($mtime));

    # If modified since
    my $headers = $self->req->headers;
    if (my $date = $headers->if_modified_since) {
        $self->app->log->debug("not modified");
        my $since = Mojo::Date->new($date)->epoch;
        if (defined $since && $since == $mtime) {
            $res->code(304);
            return !!$self->rendered;
        }
    }

    my $size;
    if (($self->stash('format')||'') eq 'png' && ($size = $self->param("size"))) {
        if ($size !~ m/^\d{1,3}x\d{1,3}$/) {
            return $self->render(text => "invalid parameter 'size'\n", code => 400);
        }
        my $cachename = "cache_$fullname";
        if(!$self->app->chi('ThumbCache')->is_valid($cachename)) {
            my $p = new Image::Magick(depth=>8);
            $p->Read($fullname, depth=>8);
            $p->Resize($size); # make thumbnail
            $self->app->chi('ThumbCache')->set($cachename, $p->ImageToBlob(magick=>uc($self->stash('format')), depth=>8, quality=>80), { expires_in => '30 min' });
        }
        return $self->render(data => $self->app->chi('ThumbCache')->get($cachename));
    }

    $self->app->log->debug("serve static");
    my $filetype = $self->app->types->type($self->stash('format'));
    if ($filetype) {
        $res->headers->content_type($filetype)->accept_ranges('bytes');
    }
    $res->content->asset(Mojo::Asset::File->new(path => $fullname));
    return !!$self->rendered;
}

1;
# vim: set sw=4 et:
