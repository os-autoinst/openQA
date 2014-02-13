#!/usr/bin/perl -w

BEGIN { unshift @INC, 'lib', 'lib/OpenQA/modules'; }

use strict;

use Test::More;

use openqa ();

unlink $openqa::dbfile;

my $schema = openqa::connect_db();

my $f = sprintf('Schema-%s-SQLite.sql', $Schema::VERSION);
my $d = 't/schema';

unlink("$d/$f");

$schema->create_ddl_dir(['SQLite'],
                        $Schema::VERSION,
                        $d,
                        );
ok(-e "$d/$f", "schema dumped");

ok($schema->deploy == 0, "deployed");

done_testing();
