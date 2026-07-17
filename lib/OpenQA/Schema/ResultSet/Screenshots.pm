# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Screenshots;


use Mojo::Base 'DBIx::Class::ResultSet', -signatures;

use Mojo::File qw(path);
use OpenQA::Log qw(log_trace log_debug log_error);
use OpenQA::Utils qw(imagesdir);
use Feature::Compat::Try;

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
    my $schema = $self->result_source->schema;
    my $screenshot_links_rs = $schema->resultset('ScreenshotLinks');

    for my $img (@$imgs) {
        log_trace "creating $img";
        try {
            $schema->txn_do(
                sub {
                    my $res = $self->create_screenshot($img)->fetchrow_arrayref;
                    my $screenshot_id = $res ? $res->[0] : $self->find({filename => $img})->id;
                    $screenshot_links_rs->create({screenshot_id => $screenshot_id, job_id => $job_id});
                });
        }
        catch ($err) {
            if ($err =~ /screenshot_links_fk_job_id/) {
                log_debug "Job $job_id has been deleted, skipping screenshot links";
            }
            elsif ($err =~ /screenshot_links_fk_screenshot_id/) {
                log_debug "Screenshot $img has been deleted, skipping screenshot link";
            }
            else {
                die $err;
            }
        }
    }
}

# scans the image directories for untracked screenshots and deletes them
# This can take a very long time to execute if $images_dir is big. So this is meant to be executed manually, e.g.:
# OPENQA_LOGFILE=scan.log script/openqa eval 'say(STDERR app->schema->resultset("Screenshots")->scan_untracked_screenshots)' > to-delete.txt
sub scan_untracked_screenshots ($self, $images_dir = imagesdir, $delete = 0) {
    my $dbh = $self->result_source->schema->storage->dbh;
    my $sth = $dbh->prepare('SELECT count(id) FROM screenshots WHERE filename = ?');
    my $screenshots_path = path($images_dir);
    my $screenshot_paths = $screenshots_path->list_tree({max_depth => 3})->grep(qr/.*\.png/i);
    my $error_count = 0;
    my $handle_error = sub ($msg) { log_error $msg; ++$error_count; return 0 };
    for my $screenshot_path_abs (@$screenshot_paths) {
        my $screenshot_path = $screenshot_path_abs->to_rel($screenshots_path);
        $sth->execute($screenshot_path);
        my ($count) = $sth->fetchrow_array;
        $handle_error->("Unable to lookup $screenshot_path in DB: " . $sth->errstr) and next if defined $sth->err;
        next if $count;
        say $screenshot_path_abs;
        unlink $screenshot_path_abs or $handle_error->("Unable to delete $screenshot_path_abs: $!") if $delete;
    }
    return $error_count;
}

1;
