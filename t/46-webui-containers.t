#!/usr/bin/env perl
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

use Test::Most;
use Test::Warnings ':report_warnings';
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Mojo::File qw(tempdir);
use Cwd qw(cwd);
END { clean(); }

#plan skip_all => "set SCHEDULER_FULLSTACK=1 (be careful)" unless $ENV{SCHEDULER_FULLSTACK};

my $workdir = tempdir();
my $PWD     = cwd;
my $prefix  = 'webui_' . int(rand(10000)) . '_';

sub clean {
    system("docker rm -f ${prefix}gru 2>/dev/null || echo");
    system("docker rm -f ${prefix}livehandler 2>/dev/null || echo");
    system("docker rm -f ${prefix}websockets 2>/dev/null || echo");
    system("docker rm -f ${prefix}scheduler 2>/dev/null || echo");
    system("docker rm -f ${prefix}webui 2>/dev/null || echo");
    system("docker rm -f ${prefix}data 2>/dev/null || echo");
    system("docker rm -f ${prefix}db 2>/dev/null || echo");
    system("docker network rm ${prefix}testing 2>/dev/null || echo");
}

sub wait_for {
    my ($container) = @_;
    my $count = 30;
    while (system("docker logs $container 2>&1 | grep Listening >/dev/null") != 0) {
        sleep 1;
        $count = $count - 1;
        last if ($count == 0);
    }

    is(system("docker logs $container 2>&1 | grep Listening >/dev/null"), 0, "container $container is listening");
}

is(system("docker network create ${prefix}testing"), 0, 'docker cannot create the network');

my $volumes
  = "-v \"$workdir/data/factory:/data/factory\" -v \"$workdir/data/tests:/data/tests\" -v \"$PWD/docker/webui/conf:/data/conf:ro\"";

is(system('docker', 'build', '-t', 'openqa_data',  'docker/openqa_data'), 0, 'data container image can be built');
is(system('docker', 'build', '-t', 'openqa_webui', 'docker/webui'),       0, 'webui container image can be built');
is(
    system(
"docker run -d --network ${prefix}testing -e POSTGRES_PASSWORD=openqa -e POSTGRES_USER=openqa -e POSTGRES_DB=openqa --net-alias db --name ${prefix}db postgres"
    ),
    0,
    'db container started'
);
my $count = 30;
while (system("docker logs ${prefix}db 2>&1 | grep \"database system is ready to accept connections\" >/dev/null") != 0)
{
    sleep 1;
    $count = $count - 1;
    last if ($count == 0);
}

is(system("docker logs ${prefix}db 2>&1 | grep \"database system is ready to accept connections\" >/dev/null"),
    0, 'database container is accepting connections (in 30 seconds)');

#data container
is(
    system(
"docker run -d -v \"$workdir/data/factory:/data/factory\" -v \"$workdir/data/tests:/data/tests\" --name ${prefix}data openqa_data"
    ),
    0,
    'data container created'
);


# webui container
is(
    system(
"docker run -d --network ${prefix}testing -e MODE=webui -e MOJO_LISTEN=http://0.0.0.0:9526 $volumes -p 9526:9526 --name ${prefix}webui openqa_webui"
    ),
    0,
    'webui container created'
);
wait_for("${prefix}webui");
is(system("docker exec ${prefix}webui curl localhost:9526 >/dev/null"), 0, 'can connect to webui');

# scheduler container
is(
    system(
"docker run -d --network ${prefix}testing -e MODE=scheduler -e MOJO_LISTEN=http://0.0.0.0:9529 $volumes -p 9529:9529 --name ${prefix}scheduler openqa_webui"
    ),
    0,
    'scheduler container created'
);
wait_for("${prefix}scheduler");
is(system("docker exec ${prefix}scheduler curl localhost:9529 >/dev/null"), 0, 'can connect to scheduler');

# websockets container
is(
    system(
"docker run -d --network ${prefix}testing -e MODE=websockets -e MOJO_LISTEN=http://0.0.0.0:9527 $volumes -p 9527:9527 --name ${prefix}websockets openqa_webui"
    ),
    0,
    'websockets container created'
);

wait_for("${prefix}websockets");
is(system("docker exec ${prefix}websockets curl localhost:9527 >/dev/null"), 0, 'can connect to websockets');

# livehandler container
is(
    system(
"docker run -d --network ${prefix}testing -e MODE=livehandler -e MOJO_LISTEN=http://0.0.0.0:9528 $volumes -p 9528:9528 --name ${prefix}livehandler openqa_webui"
    ),
    0,
    'livehandler container created'
);
wait_for("${prefix}livehandler");
is(system("docker exec ${prefix}livehandler curl localhost:9528 >/dev/null"), 0, 'can connect to livehandler');

# gru container
is(system("docker run -d --network ${prefix}testing -e MODE=gru $volumes --name ${prefix}gru openqa_webui"),
    0, 'gru container created');
my $gru_test = "docker logs ${prefix}gru 2>&1 | grep started >/dev/null";
$count = 30;
while (system($gru_test) != 0) {
    sleep 1;
    $count = $count - 1;
    last if ($count == 0);
}
is(system($gru_test), 0, 'gru has started');

done_testing();
