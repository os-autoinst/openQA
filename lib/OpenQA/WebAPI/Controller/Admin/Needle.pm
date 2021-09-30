# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::Needle;
use Mojo::Base 'Mojolicious::Controller';

use Cwd 'realpath';
use OpenQA::Utils;
use OpenQA::WebAPI::ServerSideDataTable;
use Date::Format 'time2str';
use DateTime::Format::Pg;
use Time::Seconds;

sub index {
    my ($self) = @_;

    $self->render('admin/needle/index');
}

sub _translate_days($) {
    my ($days) = @_;
    return time2str('%Y-%m-%d %H:%M:%S', time - $days * ONE_DAY, 'UTC');
}

sub _translate_date_format($) {
    my ($datetime) = @_;
    my $datetime_obj = DateTime::Format::Pg->parse_datetime($datetime);
    return DateTime::Format::Pg->format_datetime($datetime_obj);
}

sub _translate_cond($) {
    my ($cond) = @_;

    if ($cond =~ m/^min(\d+)$/) {
        return {'>=' => _translate_days($1)};
    }
    elsif ($cond =~ m/^max(\d+)$/) {
        return [{'<' => _translate_days($1)}, {'=' => undef}];
    }
    elsif ($cond =~ m/^min(\d{4}\-\d{2}\-\d{2}\w\d{2}:\d{2}:\d{2})$/) {
        return {'>=' => _translate_date_format($1)};
    }
    elsif ($cond =~ m/^max(\d{4}\-\d{2}\-\d{2}\w\d{2}:\d{2}:\d{2})$/) {
        return [{'<' => _translate_date_format($1)}, {'=' => undef}];
    }
    die "Unknown '$cond'";
}

sub _prepare_data_table {
    my ($self, $n, $paths, $dir_rs, $needles_rs) = @_;
    my $filename = $n->filename;
    my $hash = {
        id => $n->id,
        directory => $n->directory->name,
        filename => $filename,
    };
    my $dir_path = $n->directory->path;
    my $real_dir_id;

    if ($paths->{$dir_path}) {
        $real_dir_id = $paths->{$dir_path}->{real_path_id} if $dir_path ne ($paths->{$dir_path}->{real_path} // '');
    }
    else {
        my $real_path_id = $n->directory->id;
        my $dir_real_path = realpath($dir_path);
        if ($dir_real_path && $dir_real_path ne $dir_path) {
            my $real_dir = $dir_rs->find({path => $dir_real_path});
            $real_dir_id = $real_path_id = $real_dir->id if $real_dir;
        }
        $paths->{$dir_path} = {
            real_path => $dir_real_path,
            real_path_id => $real_path_id,
        };
    }
    $n = ($real_dir_id ? $needles_rs->find({dir_id => $real_dir_id, filename => $filename}) : undef) // $n;
    return $self->populate_hash_with_needle_timestamps_and_urls($n, $hash);
}

sub ajax {
    my ($self) = @_;

    my @columns = qw(directory.name filename last_seen_time last_matched_time);

    # conditions for search/filter
    my @filter_conds;
    my $search_value = $self->param('search[value]');
    push(@filter_conds, {filename => {-like => '%' . $search_value . '%'}}) if $search_value;
    my $seen_query = $self->param('last_seen');
    if ($seen_query && $seen_query ne 'none') {
        push(@filter_conds, {last_seen_time => _translate_cond($seen_query)});
    }
    my $match_query = $self->param('last_match');
    if ($match_query && $match_query ne 'none') {
        push(@filter_conds, {last_matched_time => _translate_cond($match_query)});
    }

    OpenQA::WebAPI::ServerSideDataTable::render_response(
        controller => $self,
        resultset => 'Needles',
        columns => \@columns,
        initial_conds => [{file_present => 1}],
        filter_conds => \@filter_conds,
        additional_params => {
            prefetch => ['directory'],
            # Required for ordering by those columns and also eases filtering
            join => [qw(directory)],
        },
        prepare_data_function => sub {
            my $needle_dirs = $self->schema->resultset('NeedleDirs');
            my $needles = $self->schema->resultset('Needles');
            my %paths;
            [map { $self->_prepare_data_table($_, \%paths, $needle_dirs, $needles) } shift->all];
        },
    );
}

sub module {
    my ($self) = @_;

    my $schema = $self->schema;
    my $module = $schema->resultset('JobModules')->find($self->param('module_id'));
    my $needle = $schema->resultset('Needles')->find($self->param('needle_id'))->name;

    my $index = 1;
    for my $detail (@{$module->results->{details}}) {
        last if $detail->{needle} eq $needle;
        last if grep { $needle eq $_->{name} } @{$detail->{needles} || []};
        $index++;
    }
    $self->redirect_to('step', testid => $module->job_id, moduleid => $module->name(), stepid => $index);
}

sub delete {
    my ($self) = @_;

    $self->gru->enqueue_and_keep_track(
        task_name => 'delete_needles',
        task_description => 'deleting needles',
        task_args => {
            needle_ids => $self->every_param('id'),
            user_id => $self->current_user->id,
        }
    )->then(
        sub {
            my ($result) = @_;

            my $removed_ids = ($result->{removed_ids} //= []);
            $self->emit_event(openqa_needle_delete => {id => $removed_ids}) if (@$removed_ids);
            $self->render(json => $result);
        }
    )->catch(
        sub {
            $self->reply->gru_result(@_);
        });
}

1;
