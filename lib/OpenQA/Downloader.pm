# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Downloader;
use Mojo::Base -base, -signatures;

use Mojo::Loader 'load_class';
use Mojo::File 'path';
use Mojo::URL;
use OpenQA::UserAgent;
use OpenQA::Utils 'human_readable_size';
use Time::HiRes 'sleep';
use Feature::Compat::Try;

has attempts => 5;
has [qw(log tmpdir)];
has sleep_time => 5;
has ua => sub { OpenQA::UserAgent->new(max_redirects => 5, max_response_size => 0) };
has res => undef;

sub download ($self, $url, $target, $options = {}) {
    my $log = $self->log;

    local $ENV{MOJO_TMPDIR} = $self->tmpdir;

    my $remaining_attempts = $self->attempts;
    my ($code, $err);
    while (1) {
        $options->{on_attempt}->() if $options->{on_attempt};
        ($code, $err) = $self->_get($url, $target, $options);
        return undef unless defined $err;

        if ((--$remaining_attempts) && (!defined $code || ($code =~ /^5[0-9]{2}$/))) {
            my $time = $self->sleep_time;
            my $short_error_message = $code ? "Download error $code" : 'Download error';
            $log->info("$short_error_message, waiting $time seconds for next try ($remaining_attempts remaining)");
            sleep $time;
            next;
        }
        elsif (!$remaining_attempts) {
            $options->{on_failed}->() if $options->{on_failed};
        }
        last;
    }
    return $err;
}

sub _extract_asset ($self, $to_extract, $target) {
    my $cmd;
    if ($to_extract =~ qr/\.tar(\..*)?/) {
        # invoke bsdtar to extract (compressed) tar archives
        try { $target->make_path }
        catch ($e) { return $e }    # uncoverable statement
        $cmd = "bsdtar -x --directory '$target' -f '$to_extract' 2>&1";
    }
    else {
        # invoke bsdcat to extract compressed raw files
        $cmd = "bsdcat '$to_extract' 2>&1 1>'$target'";
    }

    my $stderr = `$cmd`;
    my ($res, $err) = ($?, $!);
    my ($signal, $return_code) = ($res & 127, $res >> 8);
    chomp $stderr and $stderr = ": $stderr" if $stderr;
    return "Failed to invoke \"$cmd\": $err" if $res == -1;    # uncoverable statement
    return "Command \"$cmd\" died with signal $signal$stderr" if $signal;    # uncoverable statement
    return "Command \"$cmd\" exited with non-zero return code $return_code$stderr" if $return_code != 0;
    return undef;
}

sub _get ($self, $url, $target, $options) {
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

    my $code = $res->code;
    my $error = $res->error // {message => 'Unknown error'};
    if (defined $code && $code == 304) {
        $options->{on_unchanged}->() if $options->{on_unchanged};
        return (undef, -e $target ? undef : $error->{message});
    }

    if (!$res->is_success) {
        my $error_message = defined $code ? "$code $error->{message}" : $error->{message};
        my $log_message = qq{Download of "$target" failed: $error_message};
        $log->info($log_message);
        return ($code, $log_message);
    }

    unlink $target;
    $options->{on_downloaded}->() if $options->{on_downloaded};

    my $asset = $res->content->asset;
    my $size = $asset->size;
    my $headers = $res->headers;
    my ($ret, $err);
    if ($size == $headers->content_length) {
        if ($options->{extract}) {
            my $tempfile = path($ENV{MOJO_TMPDIR}, Mojo::URL->new($url)->path->parts->[-1])->to_string;
            $log->info(qq{Extracting "$tempfile" to "$target"});
            $asset->move_to($tempfile);
            $target = path($target);
            $err = $self->_extract_asset($tempfile, $target);
            unlink $tempfile;
            if ($err) {
                $ret = $code;
                $log->error(qq{Extracting "$tempfile" failed: $err});
                try { $target->remove_tree }
                catch ($e) {
                    $log->error("Unable to remove leftovers after failed extraction: $e")    # uncoverable statement
                }
            }
        }
        else { $asset->move_to($target) }

        $options->{on_success}->($res) if $options->{on_success};
    }
    else {
        my $header_size = human_readable_size($headers->content_length);
        my $actual_size = human_readable_size($size);
        $err = qq{Size of "$target" differs, expected $header_size but downloaded $actual_size};
        $log->info($err);
    }

    return ($ret, $err);
}

1;
