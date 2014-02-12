package db_helpers;

sub _create_timestamp_trigger
{
    my $schema = shift;
    my $table = shift;
    my $action = shift;

    my $timestamp;
    if ($action eq 'UPDATE') {
        $timestamp = 't_updated';
    } elsif ($action eq 'INSERT') {
        $timestamp = 't_created';
    } else {
        die "invalid action, must be INSERT or UPDATE\n";
    }

    $schema->add_trigger(
        name                => 'trigger_'.$table.'_'.$timestamp,
        perform_action_when => 'AFTER',
        database_events     => [$action],
        fields              => [$timestamp],
        on_table            => $table,
        action              => "UPDATE $table SET $timestamp = datetime('now') WHERE id = NEW.id;",
        schema              => $schema,
    );

}

sub create_auto_timestamps
{
    my $schema = shift;
    my $table = shift;

    _create_timestamp_trigger($schema, $table, 'INSERT');
    _create_timestamp_trigger($schema, $table, 'UPDATE');
}

1;
