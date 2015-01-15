package db_profiler;

use strict;
use base 'DBIx::Class::Storage::Statistics';

use Time::HiRes qw(time);

my $start;
my $msg;

sub query_start {
    my $self = shift();
    my $sql = shift();
    my @params = @_;

    $msg = "$sql: ".join(', ', @params);
    $start = time();
}

sub query_end {
    my $self = shift();
    my $sql = shift();
    my @params = @_;

    my $elapsed = time() - $start;
    $self->print(sprintf("[DBIx debug] Took %.8f seconds executed: %s.\n", $elapsed, $msg));
    $start = undef;
    $msg = '';
}

1;
