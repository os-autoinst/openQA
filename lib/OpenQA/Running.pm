package OpenQA::Running;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use awstandard;
BEGIN { $ENV{MAGICK_THREAD_LIMIT}=1; }
use Image::Magick;
use Mojolicious::Static;

sub init {
    my $self = shift;
    my $job = Scheduler::job_get($self->param('testid'));
    $self->stash('job', $job);

    my $testdirname = $job->{'settings'}->{'NAME'};
    $self->stash('testdirname', $testdirname);

    my $basepath = running_log($testdirname);
    $self->stash('basepath', $basepath);

    if ($basepath eq '') {
        $self->render_not_found;
        return 0;
    }

    1;
}

sub modlist {
    my $self = shift;
    return 0 unless $self->init();

    my $results = test_result($self->stash('testdirname'));
    my $modinfo = get_running_modinfo($results);
    if (defined $modinfo) {
        $self->render(json => $modinfo->{'modlist'});
    } else {
        $self->render_not_found;
    }
}

sub status {
    my $self = shift;
    return 0 unless $self->init();

    my $results = test_result($self->stash('testdirname'));
    delete $results->{'testmodules'};
    delete $results->{'distribution'};
    $self->render(json => $results);
}

sub edit {
    my $self = shift;
    return 0 unless $self->init();

    my $results = test_result($self->stash('testdirname'));
    my $moduleid = $results->{'running'};
    my $module = test_result_module($results->{'testmodules'}, $moduleid);
    if ($module) {
        my $stepid = scalar(@{$module->{'details'}});
        $self->redirect_to('edit_step', moduleid => $moduleid, stepid => $stepid);
    } else {
        $self->render_not_found;
    }
}

sub livelog {
    my $self = shift;
    return 0 unless $self->init();

    my $logfile = $self->stash('basepath').'autoinst-log.txt';
    
    # We'll open the log file and keep the filehandle.
    my $log;
    unless (open($log, $logfile)) {
        $self->render_not_found;
        return;
    }
    $self->render_later;
    $self->res->code(200);
    $self->res->headers->content_type("text/plain");

    # Send the last 10KB of data from the logfile, so that
    # the client sees some data immediately
    my $ino = (stat $logfile)[1];

    my $size = -s $logfile;
    if ($size > 10*1024 && seek $log, -10*1024, 2) {
        # Discard one (probably) partial line
        my $dummy = <$log>;
    }
    while (defined(my $l = <$log>)) {
        $self->write_chunk($l);
    }
    seek $log, 0, 1;

    # Now we set up a recurring timer to check for new lines from the
    # logfile and send them to the client, plus a utility function to
    # close the connection if anything goes wrong.
    my $id;
    my $close = sub {
        Mojo::IOLoop->remove($id);
        $self->finish;
        close $log;
        return;
    };
    $id = Mojo::IOLoop->recurring(1 => sub {
        my @st = stat $logfile;

        # Zero tolerance for any shenanigans with the logfile, such as
        # truncation, rotation, etc.
        unless (@st && $st[1] == $ino &&
                $st[3] > 0 && $st[7] >= $size)
        {
            return $close->();
        }

        # If there's new data, read it all and send it out. Then
        # seek to the current position to reset EOF.
        if ($size < $st[7]) {
            $size = $st[7];
            while (defined(my $l = <$log>)) {
                $self->write_chunk($l);
            }
            seek $log, 0, 1;
        }
    });

    # If the client closes the connection, we can stop monitoring the
    # logfile.
    $self->on(finish => sub {
            Mojo::IOLoop->remove($id);
    });
}

sub png2jpg($) {
  my $p = new Image::Magick(depth=>8);
  my $name = shift;
  $p->Read($name, depth=>8);
  return $p->ImageToBlob(magick=>uc('jpg'), depth=>8, quality=>100);
}

sub streaming {
    my $self = shift;
    return 0 unless $self->init();

    $self->render_later;
    Mojo::IOLoop->stream($self->tx->connection)->timeout(900);
    $self->res->code(200);
    $self->res->headers->content_type('multipart/x-mixed-replace;boundary=openqashot');
    $self->write_chunk("--openqashot\015\012");

    my $sendimgtwice = ($self->req->headers->user_agent=~m/Chrome/)?1:0;
    my $lastfile = '';
    my $basepath = $self->stash('basepath');
    my $p2 = Image::Magick->new(depth=>8);
    $p2->Set(size=>'800x600');

    # Set up a recurring timer to send the last screenshot to the client,
    # plus a utility function to close the connection if anything goes wrong.
    my $id;
    my $close = sub {
        Mojo::IOLoop->remove($id);
        $self->finish;
        return;
    };
    $id = Mojo::IOLoop->recurring(0.3 => sub {
        my @imgfiles=<$basepath/qemuscreenshot/*.png>;
        my $newfile = ($imgfiles[-1])?$imgfiles[-1]:$lastfile;
        if ($lastfile ne $newfile) {
            if ( !-l $newfile || !$lastfile ) {
                my $data=file_content($newfile);
                my $p = new Image::Magick(depth=>8, magick=>"PNG");
                $p->BlobToImage($data);
                my $p3=$p;
                my $jpg=$p3->ImageToBlob(magick=>'JPEG', depth=>8, quality=>60);
                my $jpgsize=length($jpg);
                for(0..$sendimgtwice) {
                    $self->write_chunk("Content-Type: image/jpeg\015\012Content-Size: $jpgsize\015\012\015\012".$jpg."\015\012--openqashot\015\012");
                }
                $lastfile = $imgfiles[-1];
            } elsif (! -e $basepath.'backend.run') {
                # Some browsers can't handle mpng (at least after reciving jpeg all the time)
                my $jpg=png2jpg($self->app->static->file('images/suse-tested.png')->path);
                my $jpgsize=length($jpg);
                $self->write_chunk("Content-Type: image/jpeg\015\012Content-Size: $jpgsize\015\012\015\012".$jpg."\015\012--openqashot--\015\012");
                $close->();
            }
        }
    });

    $self->on(finish => sub { Mojo::IOLoop->remove($id) });
}

1;
