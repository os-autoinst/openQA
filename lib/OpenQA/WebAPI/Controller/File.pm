# Copyright 2014-2016 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::File;
use Mojo::Base 'Mojolicious::Controller';

BEGIN { $ENV{MAGICK_THREAD_LIMIT} = 1; }

use OpenQA::Utils qw(:DEFAULT prjdir assetdir imagesdir);
use File::Basename;
use File::Spec;
use File::Spec::Functions 'catfile';
use Data::Dump 'pp';
use Mojo::File 'path';

sub needle {
    my $self = shift;

    # do the format splitting ourselves instead of using mojo to restrict the suffixes
    # 13.1.png would be format 1.png otherwise
    my ($name, $dummy, $format) = fileparse($self->param('name'), qw(.png .txt));
    my $distri = $self->param('distri');
    my $version = $self->param('version') || '';
    my $jsonfile = $self->param('jsonfile') || '';

    # locate the needle in the needle directory for the given distri and version
    my $needledir = needledir($distri, $version);

    # make sure the directory of the file parameter is a real subdir of testcasedir before
    # using it to find needle subdirectory, to prevent access outside of the zoo
    if ($jsonfile && !is_in_tests($jsonfile)) {
        my $prjdir = prjdir();
        warn "$jsonfile is not in a subdir of $prjdir/share/tests or $prjdir/tests";
        return $self->render(text => 'Forbidden', status => 403);
    }
    # Reject directory traversal breakouts here...
    if (index($jsonfile, '..') != -1) {
        warn "jsonfile value $jsonfile is invalid, cannot contain ..";
        return $self->render(text => 'Forbidden', status => 403);
    }
    # we need to handle the needle being in a subdirectory - we cannot assume it is always just
    # '$needledir/$name.$format'. figure out subdirectory elements from the JSON file path
    # Note this means you cannot just browse to /needles/distri/subdir/needle.png;
    # you can only find needles in subdirectories by passing the jsonfile parameter
    my ($dummy1, $path, $dummy2) = fileparse($jsonfile);
    # drop the trailing / from $path
    $path = substr($path, 0, -1);
    if (index($path, '/needles') != -1) {
        # we got something like /var/lib/openqa/share/tests/distri/needles/(subdir)/needle.json
        my @elems = split('/needles', $path, 2);
        if (defined $elems[1]) {
            $needledir .= $elems[1];
        }
    }
    elsif ($path ne '.') {
        # we got something like subdir/needle.json, $path will be "subdir"
        $needledir .= "/$path";
    }
    push(@{($self->{static} = Mojolicious::Static->new)->paths}, $needledir);

    # name is an URL parameter and can't contain slashes, so it should be safe
    return $self->serve_static_($name . $format);
}

sub _needle_by_id_and_extension {
    my ($self, $extension) = @_;

    my $needle_id = $self->param('needle_id') or return $self->reply->not_found;
    my $needle = $self->schema->resultset('Needles')->find($needle_id) or return $self->reply->not_found;
    my $needle_dir = $needle->directory->path;
    my $needle_filename = $needle->name . $extension;

    $self->{static} = Mojolicious::Static->new;
    push(@{$self->{static}->paths}, $needle_dir);
    return $self->serve_static_($needle_filename);
}

sub needle_image_by_id {
    my ($self) = @_;
    return $self->_needle_by_id_and_extension('.png');
}

sub needle_json_by_id {
    my ($self) = @_;
    return $self->_needle_by_id_and_extension('.json');
}

sub _set_test($) {
    my $self = shift;

    $self->{job} = $self->schema->resultset("Jobs")->find({'me.id' => $self->param('testid')});
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

    # we handle this in apache, but need it in tests for asset cache
    # so minimal security is good enough
    my $path = $self->param('assetpath');
    return $self->reply->not_found if $path =~ qr/\.\./;

    my $file = path(assetdir(), $path)->to_string;
    return $self->reply->not_found unless -f $file && -r _;
    $self->reply->file($file);
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
    my $res = $self->schema->resultset('Jobs')->search(\%cond, $attrs);
    if ($res and $res->first) { %asset = $res->first->get_columns }
    else { return $self->reply->not_found }

    # find the asset path
    my $path = locate_asset($asset{type}, $asset{name}, relative => 1);
    $path = catfile($path, $self->param('subpath')) if $self->param('subpath');
    return $self->render(text => 'invalid character in path', status => 400)
      if ($path =~ /\/\.\./ || $path =~ /\.\.\//);

    # map to URL - mojo will canonicalize
    $path = $self->url_for('download_asset', assetpath => $path);
    $self->app->log->debug("redirect to $path");
    # pass the redirect to the reverse proxy - might come back to use
    # in case there is no proxy (e.g. in tests)
    return $self->redirect_to($path);
}

sub serve_static_ {
    my ($self, $asset) = @_;

    $self->app->log->debug("looking for " . pp($asset) . " in " . pp($self->{static}->paths));
    $asset = $self->{static}->file($asset) if $asset && !ref($asset);
    return $self->reply->not_found unless $asset;
    $self->app->log->debug("found " . pp($asset));

    if (ref($asset) eq "Mojo::Asset::File") {
        my $filename = basename($asset->path);
        # guess content type from extension
        if ($filename =~ m/\.([^\.]+)$/) {
            my $ext = $1;
            my $filetype = $self->app->types->type($ext);
            if ($filetype) {
                $self->res->headers->content_type($filetype);
            }
            if ($ext eq 'iso') {
                # force saveAs
                $self->res->headers->content_disposition("attachment; filename=$filename;");
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
    push @{$self->{static}->paths}, imagesdir();

    # name is an URL parameter and can't contain slashes, so it should be safe
    my $dir = $self->param('md5_dirname') || ($self->param('md5_1') . '/' . $self->param('md5_2'));
    return $self->serve_static_("$dir/.thumbs/" . $self->param('md5_basename'));
}

1;
