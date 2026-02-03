# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::Admin::Needle;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Cwd 'realpath';
use Feature::Compat::Try;
use OpenQA::Utils;
use OpenQA::WebAPI::ServerSideDataTable;
use Date::Format 'time2str';
use DateTime::Format::Pg;
use List::Util qw(any);
use Time::Seconds;

sub index ($self) { $self->render('admin/needle/index') }

sub _translate_days ($days) {
    return time2str('%Y-%m-%d %H:%M:%S', time - $days * ONE_DAY, 'UTC');
}

sub _translate_date_format ($datetime) {
    my $datetime_obj = DateTime::Format::Pg->parse_datetime($datetime);
    return DateTime::Format::Pg->format_datetime($datetime_obj);
}

sub _translate_cond ($cond) {
    my ($operator, @additional_conds) = ($cond =~ m/^min/) ? ('>=') : ('<', {'=' => undef});
    my $translated;
    if ($cond =~ m/^(min|max)(\d+)$/) {
        $translated = _translate_days($2);
    }
    elsif ($cond =~ m/^(min|max)(\d{4}\-\d{2}\-\d{2}\w\d{2}:\d{2}(:\d{2})?)$/) {
        $translated = _translate_date_format($3 ? $2 : "$2:00");
    }
    $translated ? [{$operator => $translated}, @additional_conds] : die "Unknown '$cond'";
}

sub _prepare_data_table ($self, $n, $dir_rs, $needles_rs) {
    my $filename = $n->filename;
    my $hash = {
        id => $n->id,
        directory => $n->directory->name,
        filename => $filename,
    };
    return $self->populate_hash_with_needle_timestamps_and_urls($n, $hash);
}

sub ajax ($self) {
    my @columns = qw(directory.name filename last_seen_time last_matched_time);

    # conditions for search/filter
    my @filter_conds;
    my $search_value = $self->param('search[value]');
    push(@filter_conds, {filename => {-like => '%' . $search_value . '%'}}) if $search_value;
    my $seen_query = $self->param('last_seen');
    try {
        if ($seen_query && $seen_query ne 'none') {
            push(@filter_conds, {last_seen_time => _translate_cond($seen_query)});
        }
        my $match_query = $self->param('last_match');
        if ($match_query && $match_query ne 'none') {
            push(@filter_conds, {last_matched_time => _translate_cond($match_query)});
        }
    }
    catch ($e) { return $self->render(json => {error => ($e =~ s/ at .*//sr)}, status => 400) }  # uncoverable statement

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
            [map { $self->_prepare_data_table($_, $needle_dirs, $needles) } shift->all];
        },
    );
}

sub module ($self) {
    my $schema = $self->schema;
    my $module = $schema->resultset('JobModules')->find($self->param('module_id'));
    my $needle = $schema->resultset('Needles')->find($self->param('needle_id'))->name;

    my $index = 1;
    for my $detail (@{$module->results->{details}}) {
        last if $needle eq ($detail->{needle} // '');
        last if any { $needle eq ($_->{name} // '') } @{$detail->{needles} || []};
        $index++;
    }
    $self->redirect_to('step', testid => $module->job_id, moduleid => $module->name(), stepid => $index);
}

sub delete ($self) {
    $self->gru->enqueue_and_keep_track(
        task_name => 'delete_needles',
        task_description => 'deleting needles',
        task_args => {
            needle_ids => $self->every_param('id'),
            user_id => $self->current_user->id,
        }
    )->then(
        sub ($result) {
            my $removed_ids = ($result->{removed_ids} //= []);
            $self->emit_event(openqa_needle_delete => {id => $removed_ids}) if @$removed_ids;
            $self->render(json => $result);
        })->catch(sub { $self->reply->gru_result(@_) });
}

1;
