package Schema::Result::Workers;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('workers');
__PACKAGE__->add_columns(qw/ id host instance backend seen /);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(jobs => 'Schema::Result::Jobs', 'worker_id');
__PACKAGE__->has_many(commands => 'Schema::Result::Commands', 'worker_id');

1;
