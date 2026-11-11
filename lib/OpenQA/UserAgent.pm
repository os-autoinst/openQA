# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::UserAgent;
use Mojo::Base 'Mojo::UserAgent', -signatures;

use OpenQA::Config;
use Mojo::Date;
use Mojo::File 'path';
use Mojo::Util qw(hmac_sha1_sum trim);
use Digest::SHA qw(sha256);
use MIME::Base64 qw(decode_base64 encode_base64);
use IPC::Open3 qw(open3);
use File::Spec;
use Feature::Compat::Try;
use Scalar::Util ();
use Time::Seconds;
use HTTP::Status qw(:constants);
use Carp;

has [qw(apikey apisecret base_url sshkey)];

sub new ($class, @args) {
    my $self = $class->SUPER::new(@args);
    my %args = @args;
    $args{apikey} //= $ENV{OPENQA_API_KEY};
    $args{apisecret} //= $ENV{OPENQA_API_SECRET};
    $args{sshkey} //= $ENV{OPENQA_SSH_KEY};
    for my $i (qw(apikey apisecret sshkey)) {
        $self->$i($args{$i}) if $args{$i};
    }

    $self->configure_credentials($args{api});

    # Scheduling a couple of hundred jobs takes quite some time - so we better wait a couple of minutes
    # (default is 20 seconds)
    $self->inactivity_timeout(ONE_MINUTE * 10);

    # Some urls might redirect to https and then there are internal redirects for assets
    $self->max_redirects(3);

    $self->on(start => sub ($ua, $tx) { $self->_add_headers($tx) });

    #read proxy environment variables
    $self->proxy->detect;

    return $self;
}

sub open_config_file ($host) {
    return undef unless $host;
    my $cfg = parse_config_files(lookup_config_files(path(glob '~/.config/openqa'), 'client.conf', 1));
    return $cfg && $cfg->SectionExists($host) ? $cfg : undef;
}

sub configure_credentials ($self, $host) {
    return undef unless my $cfg = open_config_file($host);
    for my $i (qw(key secret)) {
        my $attr = "api$i";
        next if $self->$attr;
        # Fetch all the values in the file and keep the last one
        my @values = $cfg->val($host, $i);
        next unless my $val = $values[-1];
        $val =~ s/\s+$//;    # remove trailing whitespace
        $self->$attr($val);
    }
    unless ($self->sshkey) {
        my @values = $cfg->val($host, 'sshkey');
        if (my $val = $values[-1]) {
            $self->sshkey($val =~ s/\s+$//r);
        }
    }
    return undef;
}

sub add_auth_headers ($headers, $url, $apikey, $apisecret, $sshkey = undef) {
    my $timestamp = time;
    $headers->header('X-API-Microtime', $timestamp);
    if ($sshkey) {
        my $data = _path_query($url) . $timestamp;
        my $signature = _ssh_sign($sshkey, $data);
        my $fingerprint = _ssh_fingerprint($sshkey);
        if ($signature && $fingerprint) {
            $headers->header('X-SSH-Signature', encode_base64($signature, ''));
            $headers->header('X-SSH-Key-Fingerprint', $fingerprint);
        }
    }
    if ($apikey && $apisecret) {
        $headers->header('X-API-Key', $apikey);
        $headers->header('X-API-Hash', hmac_sha1_sum(_path_query($url) . $timestamp, $apisecret));
    }
    return;
}

# excute ssh-keygen to sign payload
sub _ssh_sign ($keyfile, $data) {
    return '' unless $keyfile && -f $keyfile;
    my $out = '';
    try {
        open my $null, '>', File::Spec->devnull;
        my $pid = open3(my $in, my $out_fh, $null, 'ssh-keygen', '-Y', 'sign', '-n', 'openqa', '-f', $keyfile);
        print $in $data;
        close $in;
        $out = do { local $/; <$out_fh> }
          // '';
        waitpid $pid, 0;
    }
    catch ($e) {
        return '';
    }
    return '' if $? != 0;
    $out =~ s/\s+$//;    # strip trailing newline from the signature header value
    return $out;
}

sub _ssh_fingerprint ($keyfile) {
    return '' unless $keyfile && -f $keyfile;
    my $pub = '';
    try {
        open my $null, '>', File::Spec->devnull;
        my $pid = open3(my $in, my $out_fh, $null, 'ssh-keygen', '-y', '-f', $keyfile);
        close $in;
        $pub = do { local $/; <$out_fh> }
          // '';
        waitpid $pid, 0;
    }
    catch ($e) {
        return '';
    }
    return '' if $? != 0;
    my ($type, $blob) = split /\s+/, trim($pub);
    return '' unless $blob;
    return 'SHA256:' . encode_base64(sha256(decode_base64($blob)), '');
}

sub _add_headers ($self, $tx) {
    my $req = $tx->req;
    my $headers = $req->headers;
    $headers->accept('application/json') unless defined $headers->accept;
    add_auth_headers($headers, $req->url, $self->apikey, $self->apisecret, $self->sshkey);
}

sub _path_query ($url) {
    my $query = $url->query->to_string;
    # as use this for hashing, we need to make sure the query is escaping
    # space the same as the mojo url parser.
    $query =~ s,%20,+,g;
    my $r = $url->path->to_string . (length $query ? "?$query" : '');
    return $r;
}

sub evaluate_retry_after ($self, $tx) {
    return undef if !$tx || !$tx->res;
    my $retry_after = $tx->res->headers->header('Retry-After');
    return undef if !defined $retry_after || $retry_after eq '';
    return $retry_after if $retry_after =~ /^\d+$/;
    my $date = Mojo::Date->new($retry_after);
    return undef unless defined(my $epoch = $date->epoch);
    my $diff = $epoch - time;
    return $diff > 0 ? int($diff) : 0;
}

sub _retry_with_delay ($code) { !$code || $code == HTTP_TOO_MANY_REQUESTS || $code >= HTTP_INTERNAL_SERVER_ERROR }

sub delay ($self, $tx, $default_delay = 1) {
    my $retry_delay = $self->evaluate_retry_after($tx);
    $retry_delay //= $default_delay if _retry_with_delay($tx && $tx->res ? $tx->res->code : undef);
    sleep $retry_delay if $retry_delay;
}

1;

=encoding utf8

=head1 NAME

OpenQA::UserAgent - special version of Mojo::UserAgent that handles authentication

=head1 SYNOPSIS

  use OpenQA::UserAgent;

  # create new UserAgent that is meant to talk to localhost. Reads key
  # and secret from config section [localhost]
  my $ua = OpenQA::UserAgent->new(api => 'localhost');

  # specify key and secret manually
  my $ua = OpenQA::UserAgent->new(apikey => 'foo', apisecret => 'bar');

=head1 DESCRIPTION

L<OpenQA::UserAgent> inherits from L<Mojo::UserAgent>. It
automatically sets the correct authentication headers if API key and
secret are available.

API key and secret can either be set manually in the constructor, via
attributes or read from a config file. L<OpenQA::UserAgent>
tries to find a config file in $OPENQA_CONFIG,
~/.config/openqa/client.conf or /etc/openqa/client.conf and reads
whatever comes first.

See L<Mojo::UserAgent> for more.

=head1 ATTRIBUTES

L<OpenQA::UserAgent> implmements the following attributes.

=head2 apikey

  my $apikey = $ua->apikey;
  $ua        = $ua->apikey('foo');

The API public key

=head2 apisecret

  my $apisecret = $ua->apisecret;
  $ua           = $ua->apisecret('bar');

The API secret key

=head2 sshkey

  my $sshkey = $ua->sshkey;
  $ua        = $ua->sshkey('/home/user/.ssh/id_ed25519');

Path to an SSH private key. Requests are signed with C<ssh-keygen -Y sign -n openqa>
using this key and sent as the X-SSH-Signature header, together with the key
fingerprint as X-SSH-Key-Fingerprint.

=head1 METHODS

=head2 new

  my $ua = OpenQA::UserAgent->new(api => 'localhost');
  my $ua = OpenQA::UserAgent->new(apikey => 'foo', apisecret => 'bar');

Generate the L<OpenQA::UserAgent> object.

=head1 CONFIG FILE FORMAT

The config file is in ini format. The sections are the host name of
the api.

  [openqa.example.com]
  key = foo
  secret = bar

=head1 SEE ALSO

L<Mojo::UserAgent>, L<Config::IniFiles>

=cut
