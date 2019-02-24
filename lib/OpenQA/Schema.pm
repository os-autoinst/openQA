# Copyright © 2014-2016 SUSE LLC
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

package OpenQA::Schema;

use strict;
use warnings;
use feature ':5.10';

use parent 'DBIx::Class::Schema';

use DBIx::Class::DeploymentHandler;
use Config::IniFiles;
use Cwd 'abs_path';
use Try::Tiny;
use FindBin '$Bin';
use Fcntl ':flock';
use File::Spec::Functions 'catfile';
use OpenQA::Utils ();

# after bumping the version please look at the instructions in the docs/Contributing.asciidoc file
# on what scripts should be run and how
our $VERSION = 74;

__PACKAGE__->load_namespaces;

sub _get_schema {
    state $schema;
    return \$schema;
}


sub connect_db {
    my %args  = @_;
    my $check = $args{check};
    $check //= 1;
    my $schema = _get_schema;
    unless ($$schema) {

        my $mode = $args{mode} || $ENV{OPENQA_DATABASE} || 'production';
        if ($mode eq 'test') {
            $$schema = __PACKAGE__->connect($ENV{TEST_PG});
        }
        else {
            my %ini;
            my $cfgpath       = $ENV{OPENQA_CONFIG} || "$Bin/../etc/openqa";
            my $database_file = $cfgpath . '/database.ini';
            if (-e $database_file || !$ENV{OPENQA_USE_DEFAULTS}) {
                tie %ini, 'Config::IniFiles', (-file => $database_file);
                die 'Could not find database section \'' . $mode . '\' in ' . $database_file unless $ini{$mode};
            }
            $$schema = __PACKAGE__->connect($ini{$mode});
        }
        deployment_check $$schema if ($check);
    }
    return $$schema;
}

sub disconnect_db {
    my $schema = _get_schema;
    if ($$schema) {
        $$schema->storage->disconnect;
        undef $$schema;
    }
}

sub dsn {
    my $self = shift;
    $self->storage->connect_info->[0]->{dsn};
}

sub deployment_check {
    # lock config file to ensure only one thing will deploy/upgrade DB at once
    # we use a file in prjdir/db as the lock file as the install process and
    # packages make this directory writeable by openQA user by default
    my $dblockfile = catfile($OpenQA::Utils::prjdir, 'db', 'db.lock');
    my $dblock;
    # LOCK_EX works most reliably if the file is open with write intent
    open($dblock, '>>', $dblockfile) or die "Can't open database lock file ${dblockfile}!";
    flock($dblock, LOCK_EX) or die "Can't lock database lock file ${dblockfile}!";
    my ($schema, $force_overwrite) = @_;
    $force_overwrite //= 0;
    my $dir = $FindBin::Bin;
    while (abs_path($dir) ne '/') {
        last if (-d "$dir/dbicdh");
        $dir = "$dir/..";
    }
    $dir = "$dir/dbicdh";
    die 'Cannot find database schema files' if (!-d $dir);

    my $dh = DBIx::Class::DeploymentHandler->new(
        {
            schema              => $schema,
            script_directory    => $dir,
            databases           => ['PostgreSQL'],
            sql_translator_args => {add_drop_table => 0},
            force_overwrite     => $force_overwrite
        });
    my $ret = 0;
    $ret = 2 if _try_deploy_db($dh);
    $ret = 1 if (!$ret && _try_upgrade_db($dh));
    close($dblock) or die "Can't close database lock file ${dblockfile}!";
    return $ret;
}

sub _try_deploy_db {
    my ($dh) = @_;
    my $schema = $dh->schema;
    my $version;
    try {
        $version = $dh->version_storage->database_version;
    }
    catch {
        $dh->install;
        # create system user right away
        $schema->resultset('Users')->create(
            {
                username => 'system',
                email    => 'noemail@open.qa',
                fullname => 'openQA system user',
                nickname => 'system'
            });
    };
    return !$version;
}

sub _try_upgrade_db {
    my ($dh) = @_;
    my $schema = $dh->schema;
    if ($dh->schema_version > $dh->version_storage->database_version) {
        $dh->upgrade;
        return 1;
    }
    return 0;
}

# read application secret from database
sub read_application_secrets {
    my ($self) = @_;
    # we cannot use our own schema here as we must not actually
    # initialize the db connection here. Would break for prefork.
    my $secrets = $self->resultset('Secrets');
    my @secrets = $secrets->all();
    if (!@secrets) {
        # create one if it doesn't exist
        $secrets->create({});
        @secrets = $secrets->all();
    }
    die "couldn't create secrets\n" unless @secrets;
    return [map { $_->secret } @secrets];
}

1;
# vim: set sw=4 et:
