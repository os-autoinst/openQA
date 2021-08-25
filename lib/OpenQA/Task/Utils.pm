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
use OpenQA::Log qw(log_warning);
use OpenQA::Utils qw(check_df);
use Scalar::Util qw(looks_like_number);

our (@EXPORT, @EXPORT_OK);
@EXPORT_OK = (qw(finish_job_if_disk_usage_below_percentage));

sub finish_job_if_disk_usage_below_percentage (%args) {
    my $job        = $args{job};
    my $percentage = $job->app->config->{misc_limits}->{$args{setting}};

    unless (looks_like_number($percentage) && $percentage >= 0 && $percentage <= 100) {
        log_warning "Specified value for $args{setting} is not a percentage and will be ignored.";
        return undef;
    }
    return undef if $percentage == 100;

    my $dir = $args{dir};
    my ($available_bytes, $total_bytes) = eval { check_df($dir) };
    if (my $error = $@) {
        log_warning "$error Proceeding with cleanup.";
        return undef;
    }

    my $free_percentage = $available_bytes / $total_bytes * 100;
    return undef if $free_percentage <= $percentage;
    $job->finish("Skipping, free disk space on '$dir' exceeds configured percentage $percentage %"
          . " (free percentage: $free_percentage %)");
    return 1;
}


1;
