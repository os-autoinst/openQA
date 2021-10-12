# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Downloader;
use Mojo::Base -base;

use Archive::Extract;
use Mojo::UserAgent;
use Mojo::File 'path';
use Mojo::URL;
use OpenQA::Utils 'human_readable_size';
use Try::Tiny;
use Time::HiRes 'sleep';

has attempts => 5;
has [qw(log tmpdir)];
has sleep_time => 5;
has ua => sub { Mojo::UserAgent->new(max_redirects => 5, max_response_size => 0) };
has res => undef;

sub download {
    my ($self, $url, $target, $options) = (shift, shift, shift, shift // {});

    my $log = $self->log;

    local $ENV{MOJO_TMPDIR} = $self->tmpdir;

    my $n = $self->attempts;
    my ($err, $ret);
    while (1) {
        $options->{on_attempt}->() if $options->{on_attempt};

        ($ret, $err) = $self->_get($url, $target, $options);
        return undef unless $ret;

        if ($ret =~ /^5[0-9]{2}$/ && --$n) {
            my $time = $self->sleep_time;
            $log->info("Download error $ret, waiting $time seconds for next try ($n remaining)");
            sleep $time;
            next;
        }
        elsif (!$n) {
            $options->{on_failed}->() if $options->{on_failed};
            last;
        }

        last;
    }

    return $err ? $err : "No error message recorded";
}

sub _get {
    my ($self, $url, $target, $options) = @_;

    my $ua = $self->ua;
    my $log = $self->log;

    my $file = path($target)->basename;
    $log->info(qq{Downloading "$file" from "$url"});

    # Assets might be deleted by a sysadmin
    my $tx = $ua->build_tx(GET => $url);
    my $etag = $options->{etag};
    $tx->req->headers->header('If-None-Match' => $etag) if $etag && -e $target;
    $tx = $ua->start($tx);
    my $res = $tx->res;
    $self->res($res);

    my $code = $res->code // 521;    # Used by cloudflare to indicate web server is down.
    if ($code eq 304) {
        $options->{on_unchanged}->() if $options->{on_unchanged};
        return (520, "Unknown error") unless -e $target;    # Avoid race condition between check and removal
        return (undef, undef);
    }

    if (!$res->is_success) {
        my $error = $res->error;
        my $message = ref $error eq 'HASH' ? " $error->{message}" : '';
        my $log_err = qq{Download of "$target" failed: $code$message};
        $log->info($log_err);
        return ($code, $log_err);
    }

    unlink $target;
    $options->{on_downloaded}->() if $options->{on_downloaded};

    my $asset = $res->content->asset;
    my $size = $asset->size;
    my $headers = $res->headers;
    my $ret;
    my $err;
    if ($size == $headers->content_length) {

        if ($options->{extract}) {
            my $tempfile = path($ENV{MOJO_TMPDIR}, Mojo::URL->new($url)->path->parts->[-1])->to_string;
            $log->info(qq{Extracting "$tempfile" to "$target"});
            $asset->move_to($tempfile);

            # Extract the temp archive file to the requested asset location
            try {
                die "Could not determine archive type\n"
                  unless my $ae = Archive::Extract->new(archive => $tempfile);
                die $ae->error unless $ae->extract(to => $target);
            }
            catch {
                $log->error(qq{Extracting "$tempfile" failed: $_});
                $err = $_;
                $ret = $code;
            };

            unlink $tempfile;
        }
        else { $asset->move_to($target) }

        $options->{on_success}->($res) if $options->{on_success};
    }
    else {
        my $header_size = human_readable_size($headers->content_length);
        my $actual_size = human_readable_size($size);
        $err = qq{Size of "$target" differs, expected $header_size but downloaded $actual_size};
        $log->info($err);
        $ret = 598;    # 598 (Informal convention) Network read timeout error
    }

    return ($ret, $err);
}

1;
