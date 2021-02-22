# Copyright (C) 2021 SUSE LLC
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

package OpenQA::Task::Utils;
use Mojo::Base -signatures;

use Exporter qw(import);
use Filesys::Df qw(df);
use Scalar::Util qw(looks_like_number);
use OpenQA::Log qw(log_warning);

our (@EXPORT, @EXPORT_OK);
@EXPORT_OK = (qw(check_df finish_job_if_disk_usage_below_percentage));

sub check_df ($dir) {
    my $df              = Filesys::Df::df($dir, 1) // {};
    my $available_bytes = $df->{bavail};
    my $total_bytes     = $df->{blocks};
    die "Unable to determine disk usage of '$dir'"
      unless looks_like_number($available_bytes)
      && looks_like_number($total_bytes)
      && $total_bytes > 0
      && $available_bytes >= 0
      && $available_bytes <= $total_bytes;
    return ($available_bytes, $total_bytes);
}

sub finish_job_if_disk_usage_below_percentage (%args) {
    my $job        = $args{job};
    my $percentage = $job->app->config->{misc_limits}->{$args{setting}};
    return undef unless $percentage;

    unless (looks_like_number($percentage) && $percentage > 0 && $percentage < 100) {
        log_warning "Specified value for $args{setting} is not a percentage and will be ignored.";
        return undef;
    }

    my $dir = $args{dir};
    my ($available_bytes, $total_bytes) = eval { check_df($dir) };
    if (my $error = $@) {
        log_warning "$error Proceeding with cleanup.";
        return undef;
    }

    my $used_percentage = 100 - $available_bytes / $total_bytes * 100;
    return undef if $used_percentage < $percentage;
    $job->finish("Skipping, disk usage of '$dir' is below configured percentage $percentage %"
          . " (used percentage: $used_percentage %)");
    return 1;
}


1;
