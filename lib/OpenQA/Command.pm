# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Command;
use Mojo::Base 'Mojolicious::Command', -signatures;

use Cpanel::JSON::XS ();
use OpenQA::Client;
use Mojo::IOLoop;
use Mojo::Util qw(encode decode getopt);
use Mojo::URL;
use Mojo::File qw(path);
use Mojo::Transaction::HTTP;
use Term::ANSIColor qw(colored);

my $JSON = Cpanel::JSON::XS->new->utf8->canonical->allow_nonref->allow_unknown->allow_blessed->convert_blessed
  ->stringify_infnan->escape_slash->allow_dupkeys->pretty;
my $PARAM_RE = qr/^([[:alnum:]_\[\]\.\:]+)=(.*)$/s;

has apibase => '/api/v1';
has [qw(apikey apisecret host)];
has name => 'openqa-cli';
has host => 'http://localhost';
has options => undef;

sub client ($self, $url) {
    my $client = OpenQA::Client->new(apikey => $self->apikey, apisecret => $self->apisecret, api => $url->host)
      ->ioloop(Mojo::IOLoop->singleton);
    $client->transactor->name($self->name);
    return $client;
}

sub data_from_stdin {
    vec(my $r = '', fileno(STDIN), 1) = 1;
    return !-t STDIN && select($r, undef, undef, 0) ? join '', <STDIN> : '';
}

sub decode_args ($self, @args) {
    return map { decode 'UTF-8', $_ } @args;
}

sub handle_result ($self, $tx, $orig_tx = undef) {
    my $res = $tx->res;
    my $is_json = ($res->headers->content_type // '') =~ m!application/json!;

    my $err = $res->error;
    my $is_connection_error = $err && !$err->{code};

    my $options = $self->options;
    if ($options->{links}) {
        my $links = $res->headers->links;
        for my $rel (sort keys %$links) {
            print STDERR colored(['green'], "$rel: $links->{$rel}{link}", "\n");
        }
    }

    if ($options->{verbose} && !$is_connection_error) {
        my $version = $res->version;
        my $code = $res->code;
        my $msg = $res->message;
        print "HTTP/$version $code $msg\n", $res->headers->to_string, "\n\n";
    }

    elsif (!$options->{quiet} && $err) {
        my $code = $err->{code} // '';
        $code .= ' ' if length $code;
        my $msg = $err->{message};
        print STDERR colored(['red'], "$code$msg", "\n");
    }

    if ($options->{pretty} && $is_json) { print $JSON->encode($res->json) }
    elsif (length(my $body = $res->body)) { say $body }

    $orig_tx->res($tx->res) if $orig_tx;
    return $err ? 1 : 0;
}

sub parse_headers ($self, @headers) {
    return {map { /^\s*([^:]+)\s*:\s*(.*+)$/ ? ($1, $2) : () } @headers};
}

sub parse_params ($self, $args, $param_file) {
    my %params;
    for my $arg (@{$args}) {
        next unless $arg =~ $PARAM_RE;
        push @{$params{$1}}, $2;
    }

    for my $arg (@{$param_file}) {
        next unless $arg =~ $PARAM_RE;
        push @{$params{$1}}, path($2)->slurp;
    }

    return \%params;
}

sub run ($self, @args) {
    my %options = (pretty => 0, quiet => 0, links => 0, verbose => 0);
    getopt \@args, ['pass_through'],
      'apibase=s' => sub { $self->apibase($_[1]) },
      'apikey=s' => sub { $self->apikey($_[1]) },
      'apisecret=s' => sub { $self->apisecret($_[1]) },
      'host=s' => sub { $self->host($_[1] =~ m!^/|://! ? $_[1] : "https://$_[1]") },
      o3 => sub { $self->host('https://openqa.opensuse.org') },
      osd => sub { $self->host('http://openqa.suse.de') },
      'L|links' => \$options{links},
      'name=s' => sub { $self->name($_[1]) },
      'p|pretty' => \$options{pretty},
      'q|quiet' => \$options{quiet},
      'v|verbose' => \$options{verbose};

    return $self->options(\%options)->command(@args);
}

sub url_for ($self, $path) {
    # Already absolute URL
    return Mojo::URL->new($path) if $path =~ m!^(?:[^:/?#]+:|//|#)!;

    $path = "/$path" unless $path =~ m!^/!;
    return Mojo::URL->new($self->apibase . $path)->to_abs(Mojo::URL->new($self->host));
}

sub retry_tx ($self, $client, $tx, $retries = undef, $delay = undef) {
    $client->connect_timeout($ENV{MOJO_CONNECT_TIMEOUT} // 30);
    $delay //= $ENV{OPENQA_CLI_RETRY_SLEEP_TIME_S} // 3;
    $retries //= $ENV{OPENQA_CLI_RETRIES} // 0;
    my $factor = $ENV{OPENQA_CLI_RETRY_FACTOR} // 1;
    my $start = time;
    for (;; --$retries) {
        my $new_tx = $client->start(Mojo::Transaction::HTTP->new(req => $tx->req));
        my $res_code = $new_tx->res->code // 0;
        return $self->handle_result($new_tx, $tx) unless $res_code =~ /^(50[23]|0)$/ && $retries > 0;
        my $waited = time - $start;
        print STDERR encode('UTF-8',
"Request failed, hit error $res_code, retrying up to $retries more times after waiting … (delay: $delay; waited ${waited}s)\n"
        );
        sleep $delay;
        $delay *= $factor;
    }
}

1;
