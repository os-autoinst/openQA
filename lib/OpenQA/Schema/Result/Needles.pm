# Copyright (C) 2015 SUSE LLC
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::Schema::Result::Needles;
use base qw/DBIx::Class::Core/;
use File::Basename;
use Cwd "realpath";

use db_helpers;

__PACKAGE__->table('needles');
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    dir_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    filename => {
        data_type => 'text',
    },
    first_seen_module_id => {
        data_type => 'integer',
    },
    last_seen_module_id => {
        data_type => 'integer',
    },
    last_matched_module_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw/dir_id filename/]);
__PACKAGE__->belongs_to(first_seen => 'OpenQA::Schema::Result::JobModules', 'first_seen_module_id');
__PACKAGE__->belongs_to(last_seen  => 'OpenQA::Schema::Result::JobModules', 'last_seen_module_id');
__PACKAGE__->belongs_to(last_match => 'OpenQA::Schema::Result::JobModules', 'last_matched_module_id');
__PACKAGE__->belongs_to(directory  => 'OpenQA::Schema::Result::NeedleDirs', 'dir_id');

__PACKAGE__->has_many(job_modules => 'OpenQA::Schema::Result::JobModuleNeedles', 'needle_id');

sub update_needle_cache($) {
    my ($needle_cache) = @_;

    for my $needle (values %$needle_cache) {
        $needle->update;
    }
}

# save the needle informations
# be aware that giving the optional needle_cache hash ref, makes you responsible
# to call update_needle_cache after a loop
sub update_needle($$$;$) {
    my ($filename, $module, $matched, $needle_cache) = @_;

    my $schema = OpenQA::Scheduler::Scheduler::schema();
    my $guard  = $schema->txn_scope_guard;

    my $needle;
    if ($needle_cache) {
        $needle = $needle_cache->{$filename};
    }
    if (!$needle) {
        # create a canonical path out of it
        my $realpath = realpath($filename);
        my $dir = $schema->resultset('NeedleDirs')->find_or_new({path => dirname($realpath)});
        if (!$dir->in_storage) {
            # first job seen defines the name
            my $name = sprintf "%s-%s", $module->job->settings_hash->{DISTRI}, $module->job->settings_hash->{VERSION};
            $dir->name($name);
            $dir->insert;
        }
        my $basename = basename($realpath);
        $needle ||= $dir->needles->find_or_new({filename => $basename, first_seen_module_id => $module->id}, {key => 'needles_dir_id_filename'});
    }

    # normally we would not need that, but the migration is working on the jobs from past backward
    if ($needle->first_seen_module_id > $module->id) {
        $needle->first_seen_module_id($module->id);
    }

    # it's not impossible that two instances update this information independent of each other, but we don't mind
    # the *exact* last module as long as it's alive around the same time
    if (($needle->last_seen_module_id // 0) < $module->id) {
        $needle->last_seen_module_id($module->id);
    }

    if ($matched && ($needle->last_matched_module_id // 0) < $module->id) {
        $needle->last_matched_module_id($module->id);
    }
    if ($needle->in_storage) {
        # if a cache is given, the caller needs to update all needles after the call
        $needle->update unless $needle_cache;
    }
    else {
        $needle->insert;
    }
    $needle_cache->{$filename} = $needle;

    $guard->commit;
    return $needle;
}

sub name() {
    my ($self) = @_;

    return fileparse($self->filename, qw/.json/);
}

# gru task injected by migration - can be removed later
sub scan_old_jobs() {
    my ($app,   $args)  = @_;
    my ($maxid, $minid) = @$args;

    my $guard = $app->db->txn_scope_guard;

    my $jobs = $app->db->resultset("Jobs")->search({-and => [{id => {'>', $minid}}, {id => {'<=', $maxid}}]}, {order_by => 'me.id ASC'});

    my $job_modules = $app->db->resultset('JobModules')->search({job_id => {-in => $jobs->get_column('id')->as_query}})->get_column('id')->as_query;

    # make sure we're not duplicating any previous data
    $app->db->resultset('JobModuleNeedles')->search({job_module_id => {-in => $job_modules}})->delete;
    my %needle_cache;

    while (my $job = $jobs->next) {
        my $modules = $job->modules->search({"me.result" => {'!=', OpenQA::Schema::Result::Jobs::NONE}}, {order_by => 'me.id ASC'});
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
