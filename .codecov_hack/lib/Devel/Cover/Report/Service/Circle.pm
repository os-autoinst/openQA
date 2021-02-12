package Devel::Cover::Report::Codecov::Service::Circle;
use strict;
use warnings;
use utf8;

sub detect {
    return $ENV{CIRCLECI};
}

sub configuration {
    return {
        service      => 'circleci',
        build        => $ENV{CIRCLE_BUILD_NUM} . '.' . $ENV{CIRCLE_NODE_INDEX},
        job          => $ENV{CIRCLE_BUILD_NUM} . '.' . $ENV{CIRCLE_NODE_INDEX},
        commit       => $ENV{CIRCLE_SHA1},
        branch       => $ENV{CIRCLE_BRANCH},
        pull_request => $ENV{CIRCLE_PR_NUMBER},
        owner        => $ENV{CIRCLE_PROJECT_USERNAME},
        repo         => $ENV{CIRCLE_PROJECT_REPONAME},
    };
}

1;
__END__
