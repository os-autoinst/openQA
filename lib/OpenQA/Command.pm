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
use Term::ANSIColor qw(colored);

my $JSON = Cpanel::JSON::XS->new->utf8->canonical->allow_nonref->allow_unknown->allow_blessed->convert_blessed
  ->stringify_infnan->escape_slash->allow_dupkeys->pretty;
my $PARAM_RE = qr/^([[:alnum:]_\[\]\.\:]+)=(.*)$/s;

has apibase => '/api/v1';
has [qw(apikey apisecret host)];
has host => 'http://localhost';

sub client ($self, $url) {
    return OpenQA::Client->new(apikey => $self->apikey, apisecret => $self->apisecret, api => $url->host)
      ->ioloop(Mojo::IOLoop->singleton);
}

sub data_from_stdin {
    vec(my $r = '', fileno(STDIN), 1) = 1;
    return !-t STDIN && select($r, undef, undef, 0) ? join '', <STDIN> : '';
}

sub decode_args ($self, @args) {
    return map { decode 'UTF-8', $_ } @args;
}

sub handle_result ($self, $tx, $options) {
    my $res = $tx->res;
    my $is_json = ($res->headers->content_type // '') =~ m!application/json!;

    my $err = $res->error;
    my $is_connection_error = $err && !$err->{code};

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
    getopt \@args, ['pass_through'],
      'apibase=s' => sub { $self->apibase($_[1]) },
      'apikey=s' => sub { $self->apikey($_[1]) },
      'apisecret=s' => sub { $self->apisecret($_[1]) },
      'host=s' => sub { $self->host($_[1] =~ m!^/|://! ? $_[1] : "https://$_[1]") },
      'o3' => sub { $self->host('https://openqa.opensuse.org') },
      'osd' => sub { $self->host('http://openqa.suse.de') };

    return $self->command(@args);
}

sub url_for ($self, $path) {
    # Already absolute URL
    return Mojo::URL->new($path) if $path =~ m!^(?:[^:/?#]+:|//|#)!;

    $path = "/$path" unless $path =~ m!^/!;
    return Mojo::URL->new($self->apibase . $path)->to_abs(Mojo::URL->new($self->host));
}

sub retry_tx ($self, $client, $tx, $handle_args, $retries = undef, $delay = undef) {
    $delay //= $ENV{OPENQA_CLI_RETRY_SLEEP_TIME_S} // 3;
    $retries //= $ENV{OPENQA_CLI_RETRIES} // 0;
    for (;; --$retries) {
        $tx = $client->start($tx);
        my $res_code = $tx->res->code // 0;
        return $self->handle_result($tx, $handle_args) unless $res_code =~ /50[23]/ && $retries > 0;
        print encode('UTF-8',
            "Request failed, hit error $res_code, retrying up to $retries more times after waiting …\n");
        sleep $delay;
    }
}

1;
