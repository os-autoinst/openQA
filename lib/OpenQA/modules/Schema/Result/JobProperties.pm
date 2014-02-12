package Schema::Result::JobProperties;
use base qw/DBIx::Class::Core/;

use db_helpers;

# stuff like distro, version, arch etc

__PACKAGE__->table('job_settings');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
    },
    key => {
        data_type => 'text',
    },
    value => {
        data_type => 'text',
    },
    job_id => {
        data_type => 'integer',
    },
    t_created => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    t_updated => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(job => 'Schema::Result::Jobs', 'job_id');

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    db_helpers::create_auto_timestamps($sqlt_table->schema, __PACKAGE__->table);
}

1;
