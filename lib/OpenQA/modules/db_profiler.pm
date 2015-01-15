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


sub enable_sql_debugging($) {
    my ($app) = @_;
    my $storage = $app->schema->storage;
    $storage->debugobj(new db_profiler());
    $storage->debugfh(MojoDebugHandle->new($app));
    $storage->debug(1);
}

package MojoDebugHandle;

sub new {
    my ($class, $app) = @_;

    return bless { 'app' => $app }, $class;
}

sub print {
    my ($self, $line) = @_;
    chop $line;
    $self->{'app'}->app->log->debug($line);
}


1;
