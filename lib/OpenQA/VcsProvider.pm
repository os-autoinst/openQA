# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::VcsProvider;

use Mojo::Base -signatures;
use OpenQA::VcsProvider::GitHub;
use OpenQA::VcsProvider::Gitea;

sub new ($class, %args) {
    my $type = delete $args{type};
    my ($provider) = split m/:/, $type;
    $class = {gh => 'GitHub', gitea => 'Gitea'}->{$provider} or return undef;
    return "OpenQA::VcsProvider::$class"->new(%args);
}

1;
