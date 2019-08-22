package OpenQA::JobDependencies::Constants;
use Mojo::Base -base;

# Use integers instead of a string labels for DEPENDENCIES because:
#  - It's part of the primary key
#  - JobDependencies is an internal table, not exposed in the API
use constant CHAINED          => 1;
use constant PARALLEL         => 2;
use constant DIRECTLY_CHAINED => 3;
use constant DEPENDENCIES     => (CHAINED, PARALLEL, DIRECTLY_CHAINED);

my %dependency_display_names = (
    CHAINED,          => 'Chained',
    PARALLEL,         => 'Parallel',
    DIRECTLY_CHAINED, => 'Directly chained',
);

sub display_names {
    return values %dependency_display_names;
}

sub display_name {
    my ($dependency_type) = @_;
    return $dependency_display_names{$dependency_type};
}

1;
