# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Screenshots;

use strict;
use warnings;

use base 'DBIx::Class::ResultSet';

use OpenQA::Log qw(log_debug);

sub create_screenshot {
    my ($self, $img) = @_;
    my $dbh = $self->result_source->schema->storage->dbh;
    my $columns = 'filename, t_created';
    my $values = '?, now()';
    my $options = 'ON CONFLICT DO NOTHING RETURNING id';
    my $sth = $dbh->prepare("INSERT INTO screenshots ($columns) VALUES($values) $options");
    $sth->execute($img);
    return $sth;
}

sub populate_images_to_job {
    my ($self, $imgs, $job_id) = @_;

    # insert the symlinks into the DB
    my %ids;
    for my $img (@$imgs) {
        log_debug "creating $img";
        my $res = $self->create_screenshot($img)->fetchrow_arrayref;
        $ids{$img} = $res ? $res->[0] : $self->find({filename => $img})->id;
    }
    my @data = map { [$_, $job_id] } values %ids;
    $self->result_source->schema->resultset('ScreenshotLinks')->populate([[qw(screenshot_id job_id)], @data]);
}

1;
