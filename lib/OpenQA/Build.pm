package OpenQA::Build;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler;

# This tool is specific to openSUSE
# to enable the Release Team to see the quality at a glance

sub show {
    my $self  = shift;
    my $build = $self->param('buildid');

    if ( $build =~ /Build([\d.]+)$/ ) {
        $build = $1;
    }
    else {
        return $self->render( text => "invalid build", status => 403 );
    }

    $self->app->log->debug("build $build");

    my @configs = ();
    my %archs   = ();
    my %results = ();

    for my $job ( @{ Scheduler::list_jobs( 'build' => $build ) || [] } ) {
        my $testname = $job->{'name'};
        my $p        = openqa::parse_testname($testname);
        my $config   = $p->{extrainfo};
        my $type     = $p->{flavor};
        my $arch     = $p->{arch};

        my $result;
        if ( $job->{state} eq 'done' ) {
            my $r            = test_result($testname);
            my $result_stats = test_result_stats($r);
            my $overall      = "fail";
            if ( ( $r->{overall} || '' ) eq "ok" ) {
                $overall = ( $r->{dents} ) ? "unknown" : "ok";
            }
            $result = {
                ok      => $result_stats->{ok}   || 0,
                unknown => $result_stats->{unk}  || 0,
                fail    => $result_stats->{fail} || 0,
                overall => $overall,
                jobid   => $job->{id},
                state   => "done",
                testname => $testname,
            };
        }
        elsif ( $job->{state} eq 'running' ) {
            $result = {
                state    => "running",
                testname => $testname,
                jobid    => $job->{id},
            };
        }
        else {
            $result = {
                state    => $job->{state},
                testname => $testname,
                jobid    => $job->{id},
                priority => $job->{priority},
            };
        }

        # Populate @configs and %archs
        push( @configs, $config ) unless ( $config ~~ @configs ); # manage xxx.0, xxx.1 (we only want the most recent one)
        $archs{$type} = [] unless $archs{$type};
        push( @{ $archs{$type} }, $arch ) unless ( $arch ~~ @{ $archs{$type} } );

        # Populate %results
        $results{$config} = {} unless $results{$config};
        $results{$config}{$type} = {} unless $results{$config}{$type};
        $results{$config}{$type}{$arch} = $result;
    }

    # Sorting everything
    my @types = keys %archs;
    @types   = sort @types;
    @configs = sort @configs;
    for my $type (@types) {
        my @sorted = sort( @{ $archs{$type} } );
        $archs{$type} = \@sorted;
    }

    $self->stash(
        build   => $build,
        configs => \@configs,
        types   => \@types,
        archs   => \%archs,
        results => \%results,
    );
}

1;
