#!/usr/bin/perl -w

BEGIN { unshift @INC, 'lib', 'lib/OpenQA/modules'; }

use strict;

use Test::More;

use openqa ();

use Schema::Schema; 

unlink $openqa::dbfile;

my $schema = Schema->connect({
    dsn => "dbi:SQLite:dbname=$openqa::dbfile",
    on_connect_call => "use_foreign_keys",
});

my $f = 'Schema-1-SQLite.sql';
my $d = 't/schema';

unlink("$d/$f");

$schema->create_ddl_dir(['SQLite'],
                        $Schema::VERSION,
                        $d,
                        );
ok(-e "$d/$f", "schema dumped");

ok($schema->deploy == 0, "deployed");

done_testing();
