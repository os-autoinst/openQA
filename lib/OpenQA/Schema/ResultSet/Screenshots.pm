# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Screenshots;


use Mojo::Base 'DBIx::Class::ResultSet', -signatures;

use OpenQA::Log qw(log_trace);

sub create_screenshot ($self, $img) {
    my $dbh = $self->result_source->schema->storage->dbh;
    my $columns = 'filename, t_created';
    my $values = '?, now()';
    my $options = 'ON CONFLICT DO NOTHING RETURNING id';
    my $sth = $dbh->prepare("INSERT INTO screenshots ($columns) VALUES($values) $options");
    $sth->execute($img);
    return $sth;
}

# insert the symlinks into the DB
sub populate_images_to_job ($self, $imgs, $job_id) {
    my %ids;
    for my $img (@$imgs) {
        log_trace "creating $img";
        my $res = $self->create_screenshot($img)->fetchrow_arrayref;
        $ids{$img} = $res ? $res->[0] : $self->find({filename => $img})->id;
    }
    my @data = map { [$_, $job_id] } values %ids;
    $self->result_source->schema->resultset('ScreenshotLinks')->populate([[qw(screenshot_id job_id)], @data]);
}

1;
