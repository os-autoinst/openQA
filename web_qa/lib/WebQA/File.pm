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

sub image {
  my $self = shift;
  my $fullname = shift;

  return $self->render_not_found if (!-e $fullname);

  my $p = new Image::Magick(depth=>8);
  $p->Read($fullname, depth=>8);
  my $size = $self->param("size");
  if ($size && $size=~m/^\d{1,3}x\d{1,3}$/) {
    $p->Resize($size); # make thumbnail
  }

  return $self->render(data => $p->ImageToBlob(magick=>uc($self->stash('format')), depth=>8, quality=>80));
}

1;
