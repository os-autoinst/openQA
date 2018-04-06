# Copyright (C) 2018 SUSE LLC
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

package OpenQA::Task::Needle::Scan;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Utils;
use Mojo::URL;

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(scan_old_jobs => sub { _old_jobs($app, @_) });
    #    if exists $app->{minion} && defined $app->{minion};
    $app->minion->add_task(scan_needles => sub { _needles($app, @_) });
    #  if exists $app->{minion} && defined $app->{minion};

}

sub _needles {
    my ($app, $minion, $args) = @_;

    my $dirs = $app->db->resultset('NeedleDirs');

    while (my $dir = $dirs->next) {
        my $needles = $dir->needles;
        while (my $needle = $needles->next) {
            $needle->check_file;
            $needle->update;
        }
    }
    return;
}

sub _old_jobs {
    my ($app,   $args)  = @_;
    my ($maxid, $minid) = @$args;
    my $guard = $app->db->txn_scope_guard;

    my $jobs = $app->db->resultset("Jobs")
      ->search({-and => [{id => {'>', $minid}}, {id => {'<=', $maxid}}]}, {order_by => 'me.id ASC'});

    my $job_modules = $app->db->resultset('JobModules')->search({job_id => {-in => $jobs->get_column('id')->as_query}})
      ->get_column('id')->as_query;

    # make sure we're not duplicating any previous data
    $app->db->resultset('JobModuleNeedles')->search({job_module_id => {-in => $job_modules}})->delete;
    my %needle_cache;

    while (my $job = $jobs->next) {
        my $modules = $job->modules->search({"me.result" => {'!=', OpenQA::Schema::Result::Jobs::NONE}},
            {order_by => 'me.id ASC'});
        while (my $module = $modules->next) {

            $module->job($job);
            my $details = $module->details();
            next unless $details;

            $module->store_needle_infos($details, \%needle_cache);
        }
    }
    OpenQA::Schema::Result::Needles::update_needle_cache(\%needle_cache);
    $guard->commit;
}

1;
