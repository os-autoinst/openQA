package WebQA::File;
use Mojo::Base 'Mojolicious::Controller';
BEGIN { $ENV{MAGICK_THREAD_LIMIT}=1; }
use Image::Magick;
use openqa;

sub test_image {
  my $self = shift;

  my $name = $self->param('filename');
  my $testname = $self->param('testid');
  my $fullname = openqa::testresultdir($testname)."/$name.".$self->stash('format');
  $self->image($fullname);
}

sub needle {
  my $self = shift;

  my $name = $self->param('name');
  $name =~ s/\.([^.]+)$//; # Remove file extension
  $self->stash('format', $1);
  my $distri = $self->param('distri');
  my $version = $self->param('version') || '';
  if ($self->stash('format') eq 'json') {
    my $fullname = openqa::needle_info($name, $distri, $version)->{'json'};
    $self->render_static($fullname);
  } else {
    my $info = openqa::needle_info($name, $distri, $version);
    $self->image($info->{'image'});
  }
}

sub image {
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

  my $size = $self->param("size");
  if ($size) {
    if ($size !~ m/^\d{1,3}x\d{1,3}$/) {
      $res->code(400);
      return !!$self->rendered;
    }
    my $p = new Image::Magick(depth=>8);
    $p->Read($fullname, depth=>8);
    $p->Resize($size); # make thumbnail
    return $self->render(data => $p->ImageToBlob(magick=>uc($self->stash('format')), depth=>8, quality=>80));
  } else {
    $self->app->log->debug("serve static");
    $res->content->asset(Mojo::Asset::File->new(path => $fullname));
    return !!$self->rendered;
  }
}

1;
