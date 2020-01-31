# Copyright (C) 2020 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Downloader;
use Mojo::Base -base;

use Archive::Extract;
use Mojo::UserAgent;
use Mojo::File 'path';
use Mojo::URL;
use OpenQA::Utils 'human_readable_size';

has attempts => 5;
has [qw(log tmpdir)];
has sleep_time => 5;
has ua         => sub { Mojo::UserAgent->new(max_redirects => 2, max_response_size => 0) };

sub download {
    my ($self, $url, $target, $options) = (shift, shift, shift, shift // {});

    my $log = $self->log;

    local $ENV{MOJO_TMPDIR} = $self->tmpdir;

    my $n = $self->attempts;
    while (1) {
        $options->{on_attempt}->() if $options->{on_attempt};

        my $ret;
        eval { $ret = $self->_get($url, $target, $options) };
        return 1 unless $ret;

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

    return undef;
}

sub _get {
    my ($self, $url, $target, $options) = @_;

    my $ua  = $self->ua;
    my $log = $self->log;

    my $file = path($target)->basename;
    $log->info(qq{Downloading "$file" from "$url"});

    # Assets might be deleted by a sysadmin
    my $tx   = $ua->build_tx(GET => $url);
    my $etag = $options->{etag};
    $tx->req->headers->header('If-None-Match' => $etag) if $etag && -e $target;
    $tx = $ua->start($tx);
    my $res = $tx->res;

    my $ret;
    my $code = $res->code // 521;    # Used by cloudflare to indicate web server is down.
    if ($code eq 304) {
        $options->{on_unchanged}->() if $options->{on_unchanged};
        $ret = 520 unless -e $target;    # Avoid race condition between check and removal
    }

    elsif ($res->is_success) {
        unlink $target;
        $options->{on_downloaded}->() if $options->{on_downloaded};

        my $asset   = $res->content->asset;
        my $size    = $asset->size;
        my $headers = $res->headers;
        if ($size == $headers->content_length) {

            if ($options->{extract}) {
                my $tempfile = path($ENV{MOJO_TMPDIR}, $file)->to_string;
                $log->info(qq{Extracting "$tempfile" to "$target"});
                $asset->move_to($tempfile);

                # Extract the temp archive file to the requested asset location
                my $ae = Archive::Extract->new(archive => $tempfile);
                $log->error(qq{Extracting "$tempfile" failed: } . $ae->error) unless $ae->extract(to => $target);

                unlink $tempfile;
            }
            else { $asset->move_to($target) }

            $options->{on_success}->($res) if $options->{on_success};
        }
        else {
            my $header_size = human_readable_size($headers->content_length);
            my $actual_size = human_readable_size($size);
            $log->info(qq{Size of "$target" differs, expected $header_size but downloaded $actual_size});
            $ret = 598;    # 598 (Informal convention) Network read timeout error
        }
    }
    else {
        my $message = $res->error->{message};
        $log->info(qq{Download of "$target" failed: $code $message});
        $ret = $code;
    }

    return $ret;
}

1;
