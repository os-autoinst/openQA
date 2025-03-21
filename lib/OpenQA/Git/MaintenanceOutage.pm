package OpenQA::Git::MaintenanceOutage;
use Mojo::Base -strict;
use Mojo::File 'path';
use Time::Piece;

my $STATE_FILE = "/var/lib/openqa/share/gitlab_maintenance.lock";
my $MAX_DURATION_HOURS = 24;    #TODO make this a config var ?

sub decide_outcome {
    my ($app, $ctx, $error_string) = @_;

    unless (-f $STATE_FILE) {
        eval {
            path($STATE_FILE)->spurt(time . "\n");    # time of intial failure
        };
        return {skip => 1};
    }

    my $content = path($STATE_FILE)->slurp;
    my $outage_t = Time::Piece->new($content);
    my $now = Time::Piece->new;

    my $diff_hours = ($now - $outage_t) / (60 * 60);
    if ($diff_hours >= $MAX_DURATION_HOURS) {
        return {fail => 1};
    }
    else {
        return {skip => 1};
    }
}

1;

