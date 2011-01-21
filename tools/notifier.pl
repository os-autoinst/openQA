#!/usr/bin/perl -w
# A simple bot to notify about events

use strict;
use warnings;
use POE qw(Component::IRC);
use POE::Component::IRC::Plugin::Connector;

my $queuedir = '/tmp/ircboteventqueue';
my $nickname = 'openqabot';
my $ircname = 'Bernhard\'s Event Notification Bot';
my $server = 'chat.eu.freenode.net';

my @channels = ('#opensuse-openqa');


my $joined=0;
# We create a new PoCo-IRC object
my $irc = POE::Component::IRC->spawn( 
   nick => $nickname,
   ircname => $ircname,
   server => $server,
) or die "Oh noooo! $!";

POE::Session->create(
    package_states => [
        main => [ qw(_default _start irc_001 irc_public) ],
    ],
    heap => { irc => $irc },
);

$poe_kernel->run(); # main loop in here

sub _start {
    my ($kernel, $heap) = @_[KERNEL ,HEAP];

    # retrieve our component's object from the heap where we stashed it
    my $irc = $heap->{irc};

    $irc->yield( register => 'all' );
    $heap->{connector} = POE::Component::IRC::Plugin::Connector->new();
    $irc->plugin_add( 'Connector' => $heap->{connector} );
    $irc->yield( connect => { } );
    return;
}

sub irc_001 {
    my $sender = $_[SENDER];

    # Since this is an irc_* event, we can get the component's object by
    # accessing the heap of the sender. Then we register and connect to the
    # specified server.
    my $irc = $sender->get_heap();

    print "Connected to ", $irc->server_name(), "\n";

    # we join our channels
    $irc->yield( join => $_ ) for @channels;
    return;
}

# check for messages to relay to IRC
sub check_queue()
{
  return unless $joined;
  my @list=<$queuedir/*>;
  foreach my $x (@list) {
    open(my $f, "<", $x) or (warn "could not open $x: $!" and next);
    my $content=<$f>; # only first line for IRC
    close $f;
    print "relaying message $content\n";
    foreach my $c (@channels) {
      $irc->yield( privmsg => $c => "$content");
      sleep 5; # avoid overload
    }
    unlink $x; # done => delete
  }
}

sub irc_public {
    my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
    my $nick = ( split /!/, $who )[0];
    my $channel = $where->[0];

    check_queue;
    if ( my ($rot13) = $what =~ /^rot13 (.+)/ ) {
        $rot13 =~ tr[a-zA-Z][n-za-mN-ZA-M];
        $irc->yield( privmsg => $channel => "$nick: $rot13" );
    }
    return;
}

# We registered for all events, this will produce some debug info.
sub _default {
    my ($event, $args) = @_[ARG0 .. $#_];
    my @output = ( "$event: " );

    if($event eq "irc_join") {$joined=1}
    check_queue;
    for my $arg (@$args) {
        if ( ref $arg eq 'ARRAY' ) {
            push( @output, '[' . join(', ', @$arg ) . ']' );
        }
        else {
            push ( @output, "'$arg'" );
        }
    }
    print join ' ', @output, "\n";
    return 0;
}

