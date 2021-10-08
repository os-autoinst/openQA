# Copyright 2017-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
# no OpenQA::Test::TimeLimit for this trivial test

use Mojo::Base 'Mojolicious', -signatures;

use_ok('OpenQA::WebAPI::Description', qw(get_pod_from_controllers set_api_desc));
my $app = Mojolicious->new;
get_pod_from_controllers($app);

done_testing;
