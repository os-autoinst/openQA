# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Db;
use Mojo::Base -strict, -signatures;

use Mojo::SQLite;
use Mojo::File 'path';

# Default to 10 minutes
use constant SQLITE_BUSY_TIMEOUT => $ENV{OPENQA_SQLITE_BUSY_TIMEOUT} // 600000;

# Defaults to 1 minute
use constant SQLITE_SLOW_QUERY => $ENV{OPENQA_SQLITE_SLOW_QUERY} // 60000;

sub _configure_sqlite_database ($log, $sqlite, $dbh) {
    # default to using DELETE journaling mode to avoid database corruption seen in production (see poo#67000)
    # check out https://www.sqlite.org/pragma.html#pragma_journal_mode for possible values
    my $sqlite_mode = uc($ENV{OPENQA_CACHE_SERVICE_SQLITE_JOURNAL_MODE} || 'DELETE');
    $dbh->sqlite_busy_timeout(SQLITE_BUSY_TIMEOUT);
    $dbh->do("pragma journal_mode=$sqlite_mode");
    $dbh->do('pragma synchronous=NORMAL') if $sqlite_mode eq 'WAL';

    # Log slow queries
    $dbh->sqlite_profile(
        sub ($statement, $elapsed, @) {
            $log->info(qq{Slow SQLite query: "$statement" -> ${elapsed}ms}) if $elapsed > SQLITE_SLOW_QUERY;
        });
}

sub location ($global_settings) { $ENV{OPENQA_CACHE_DIR} || $global_settings->{CACHEDIRECTORY} }

sub db_file ($location, $file_name = 'cache.sqlite') { path($location, $file_name) }

sub open_sqlite_database ($log, $db_file) {
    my $sqlite = Mojo::SQLite->new->from_string("file://$db_file?no_wal=1");
    $sqlite->on(connection => sub ($sqlite, $dbh) { _configure_sqlite_database($log, $sqlite, $dbh) });
    return $sqlite;
}

sub open_default_sqlite_database ($log, $location) { open_sqlite_database($location, db_file($location)) }

1;
