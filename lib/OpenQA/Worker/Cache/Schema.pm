package OpenQA::Worker::Cache::Schema;

# based on the DBIx::Class Schema base class
use base 'DBIx::Class::Schema';
use Fcntl ':flock';
use strict;
use warnings;


# This will load any classes within
# Moblo::Schema::Result and Moblo::Schema::ResultSet (if any)
__PACKAGE__->load_namespaces();

1;
