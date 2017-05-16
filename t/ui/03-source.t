# Copyright (C) 2014 SUSE Linux Products GmbH
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

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;

SKIP: {
    skip "breaks package build", 4;

    OpenQA::Test::Case->new->init_data;

    my $t = Test::Mojo->new('OpenQA::WebAPI');

    my $test_name = 'isosize';

    my $get = $t->get_ok("/tests/99938/modules/$test_name/steps/1/src")->status_is(200);
    $get->content_like(qr|inst\.d/.*$test_name.pm|i, "$test_name test source found");
    $get->content_like(qr/ISO_MAXSIZE/i,             "$test_name test source shown");
}

done_testing();
