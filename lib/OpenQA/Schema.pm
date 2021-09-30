# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

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
use OpenQA::Utils qw(:DEFAULT prjdir);

# after bumping the version please look at the instructions in the docs/Contributing.asciidoc file
# on what scripts should be run and how
our $VERSION = $ENV{OPENQA_SCHEMA_VERSION_OVERRIDE} // 93;

__PACKAGE__->load_namespaces;

my $SINGLETON;

sub connect_db {
    my %args = @_;
    my $check_deploy = $args{deploy};
    $check_deploy //= 1;

    unless ($SINGLETON) {

        my $mode = $args{mode} || $ENV{OPENQA_DATABASE} || 'production';
        if ($mode eq 'test') {
            $SINGLETON = __PACKAGE__->connect($ENV{TEST_PG});
        }
        else {
            my %ini;
            my $cfgpath = $ENV{OPENQA_CONFIG} || "$Bin/../etc/openqa";
            my $database_file = $cfgpath . '/database.ini';
            tie %ini, 'Config::IniFiles', (-file => $database_file);
            die 'Could not find database section \'' . $mode . '\' in ' . $database_file unless $ini{$mode};
            $SINGLETON = __PACKAGE__->connect($ini{$mode});
        }
        deploy $SINGLETON if $check_deploy;
    }

    return $SINGLETON;
}

sub disconnect_db {
    if ($SINGLETON) {
        $SINGLETON->storage->disconnect;
        $SINGLETON = undef;
    }
}

sub dsn {
    my $self = shift;
    return $self->storage->connect_info->[0]->{dsn};
}

sub deploy {
    my ($self, $force_overwrite) = @_;

    # lock config file to ensure only one thing will deploy/upgrade DB at once
    # we use a file in prjdir/db as the lock file as the install process and
    # packages make this directory writeable by openQA user by default
    my $dblockfile = catfile(prjdir(), 'db', 'db.lock');
    my $dblock;

    # LOCK_EX works most reliably if the file is open with write intent
    open($dblock, '>>', $dblockfile) or die "Can't open database lock file ${dblockfile}!";
    flock($dblock, LOCK_EX) or die "Can't lock database lock file ${dblockfile}!";
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
            schema => $self,
            script_directory => $dir,
            databases => ['PostgreSQL'],
            sql_translator_args => {add_drop_table => 0},
            force_overwrite => $force_overwrite
        });
    my $ret = 0;
    $ret = 2 if _try_deploy_db($dh);
    $ret = 1 if (!$ret && _try_upgrade_db($dh));
    close($dblock) or die "Can't close database lock file ${dblockfile}!";
    return $ret;
}

# Class attribute used for testing with OpenQA::Test::Database
sub search_path_for_tests {
    my $class = shift;
    state $search_path;
    $search_path = shift if @_;
    return $search_path;
}

# Class method everyone should use to access the schema
sub singleton { $SINGLETON || connect_db() }

sub _try_deploy_db {
    my ($dh) = @_;

    my $schema = $dh->schema;
    my $version;
    try {
        $version = $dh->version_storage->database_version;
    }
    catch {
        # If the table does not exist, we want to deploy, and the error
        # is expected. If we get other errors like "Permission denied" in case
        # the database is not readable by the current user, we print the
        # error message
        warn "Error when trying to get the database version: $_"
          unless m/relation "dbix_class_deploymenthandler_versions" does not exist/;
        $dh->install;
        $schema->create_system_user;    # create system user right away
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

sub create_system_user {
    my ($self) = @_;

    $self->resultset('Users')->create(
        {
            username => 'system',
            email => 'noemail@open.qa',
            fullname => 'openQA system user',
            nickname => 'system'
        });
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
