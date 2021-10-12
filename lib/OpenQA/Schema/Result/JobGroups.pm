# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::JobGroups;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use Mojo::Base -signatures;
use OpenQA::App;
use OpenQA::Markdown 'markdown_to_html';
use OpenQA::JobGroupDefaults;
use Class::Method::Modifiers;
use OpenQA::Log qw(log_debug);
use OpenQA::Utils qw(parse_tags_from_comments);
use Date::Format 'time2str';
use OpenQA::YAML 'dump_yaml';
use Storable 'dclone';
use Text::Diff 'diff';
use Time::Seconds;

__PACKAGE__->table('job_groups');
__PACKAGE__->load_components(qw(Timestamps));

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    name => {
        data_type => 'text',
        is_nullable => 0,
    },
    parent_id => {
        data_type => 'integer',
        is_foreign_key => 1,
        is_nullable => 1,
    },
    size_limit_gb => {
        data_type => 'integer',
        is_nullable => 1,
    },
    exclusively_kept_asset_size => {
        data_type => 'bigint',
        is_nullable => 1,
    },
    keep_logs_in_days => {
        data_type => 'integer',
        is_nullable => 1,
    },
    keep_important_logs_in_days => {
        data_type => 'integer',
        is_nullable => 1,
    },
    keep_results_in_days => {
        data_type => 'integer',
        is_nullable => 1,
    },
    keep_important_results_in_days => {
        data_type => 'integer',
        is_nullable => 1,
    },
    default_priority => {
        data_type => 'integer',
        is_nullable => 1,
    },
    sort_order => {
        data_type => 'integer',
        is_nullable => 1,
    },
    description => {
        data_type => 'text',
        is_nullable => 1,
    },
    template => {
        data_type => 'text',
        is_nullable => 1,
    },
    build_version_sort => {
        data_type => 'boolean',
        default_value => 1,
        is_nullable => 0,
    },
    carry_over_bugrefs => {
        data_type => 'boolean',
        is_nullable => 1,
    });

__PACKAGE__->add_unique_constraint([qw(name parent_id)]);

__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(jobs => 'OpenQA::Schema::Result::Jobs', 'group_id');
__PACKAGE__->has_many(comments => 'OpenQA::Schema::Result::Comments', 'group_id', {order_by => 'id'});
__PACKAGE__->belongs_to(
    parent => 'OpenQA::Schema::Result::JobGroupParents',
    'parent_id', {join_type => 'left', on_delete => 'SET NULL'});
__PACKAGE__->has_many(job_templates => 'OpenQA::Schema::Result::JobTemplates', 'group_id');

sub _get_column_or_default {
    my ($self, $column, $setting) = @_;

    if (defined(my $own_value = $self->get_column($column))) {
        return $own_value;
    }
    if (defined(my $parent = $self->parent)) {
        my $parent_column = 'default_' . $column;
        return $self->parent->$parent_column();
    }
    return OpenQA::App->singleton->config->{default_group_limits}->{$setting};
}

around 'size_limit_gb' => sub {
    my ($orig, $self) = @_;

    if (defined(my $own_value = $self->get_column('size_limit_gb'))) {
        return $own_value;
    }
    return OpenQA::App->singleton->config->{default_group_limits}->{asset_size_limit};

    # note: In contrast to other cleanup-related properties the limit for assets is not inherited from
    #       the parent group. So the default is directly read from the config.
};

around 'keep_logs_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->_get_column_or_default('keep_logs_in_days', 'log_storage_duration');
};

around 'keep_important_logs_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->_get_column_or_default('keep_important_logs_in_days', 'important_log_storage_duration');
};

around 'keep_results_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->_get_column_or_default('keep_results_in_days', 'result_storage_duration');
};

around 'keep_important_results_in_days' => sub {
    my ($orig, $self) = @_;
    return $self->_get_column_or_default('keep_important_results_in_days', 'important_result_storage_duration');
};

around 'default_priority' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('default_priority')
      // ($self->parent ? $self->parent->default_priority : OpenQA::JobGroupDefaults::PRIORITY);
};

around 'carry_over_bugrefs' => sub {
    my ($orig, $self) = @_;
    return $self->get_column('carry_over_bugrefs')
      // ($self->parent ? $self->parent->carry_over_bugrefs : OpenQA::JobGroupDefaults::CARRY_OVER_BUGREFS);
};

sub rendered_description {
    my $self = shift;
    return undef unless my $desc = $self->description;
    return Mojo::ByteStream->new(markdown_to_html($desc));
}

sub full_name {
    my ($self) = @_;

    if (my $parent = $self->parent) {
        return $parent->name . ' / ' . $self->name;
    }
    return $self->name;
}

sub matches_nested {
    my ($self, $regex) = @_;
    return $self->full_name =~ /$regex/;
}

# check the group comments for important builds
sub _important_builds ($self) {
    # determine relevant comments including those on the parent-level
    # note: Assigning to scalar first because ->comments would return all results at once when
    #       called in an array-context.
    my $not_an_array = $self->comments;
    my @comments = ($not_an_array);
    if (my $parent = $self->parent) {
        my $not_an_array = $parent->comments;
        push(@comments, $not_an_array);
    }

    # look for "important" tags in the comments
    my %importants;
    for my $comments (@comments) {
        while (my $comment = $comments->next) {
            my @tag = $comment->tag;
            next unless $tag[0];
            if ($tag[1] eq 'important') {
                $importants{$tag[0]} = 1;
            }
            elsif ($tag[1] eq '-important') {
                delete $importants{$tag[0]};
            }
        }
    }
    return \%importants;
}

sub important_builds ($self) { [sort keys %{$self->_important_builds}] }

sub _find_expired_jobs ($self, $important_builds, $keep_in_days, $keep_important_in_days,
    $preserved_important_jobs_out = undef)
{
    return undef unless $keep_in_days;    # 0 means forever

    my $now = time;
    my $timecond = {'<' => time2str('%Y-%m-%d %H:%M:%S', $now - ONE_DAY * $keep_in_days, 'UTC')};

    # filter out linked jobs
    # note: As we use this function also for the homeless group (with id=null), we can't use $self->jobs, but
    #       need to add it directly.
    my $jobs = $self->result_source->schema->resultset('Jobs');
    my @group_cond = ('me.group_id' => $self->id);
    my $expired_jobs = $jobs->search(
        {
            BUILD => {-not_in => $important_builds},
            text => {like => 'label:linked%'},
            t_finished => $timecond,
            @group_cond,
        },
        {order_by => 'me.id', join => 'comments'});
    my @linked_jobs = map { $_->id } $expired_jobs->all;

    # define condition for expired jobs in unimportant builds
    my @ors = ({BUILD => {-not_in => $important_builds}, t_finished => $timecond, id => {-not_in => \@linked_jobs}});

    # define condition for expired jobs in important builds
    my ($important_timestamp, @important_cond);
    if ($keep_important_in_days && $keep_important_in_days > $keep_in_days) {
        $important_timestamp = time2str('%Y-%m-%d %H:%M:%S', $now - ONE_DAY * $keep_important_in_days, 'UTC');
        @important_cond = (-or => [{BUILD => {-in => $important_builds}}, {id => {-in => \@linked_jobs}}]);
        push @ors, {@important_cond, t_finished => {'<' => $important_timestamp}};
    }

    # make additional query for jobs not being expired because they're important
    if ($important_timestamp && $preserved_important_jobs_out) {
        my @time_cond = (-and => [{t_finished => $timecond}, {t_finished => {'>=' => $important_timestamp}}]);
        my @search_args = ({@important_cond, @group_cond, @time_cond}, {order_by => qw(id)});
        $$preserved_important_jobs_out = $jobs->search(@search_args);
    }

    # make query for expired jobs
    return $jobs->search({-and => {@group_cond, -or => \@ors}}, {order_by => qw(id)});
}

sub find_jobs_with_expired_results ($self, $important_builds = undef) {
    $important_builds //= $self->important_builds;
    my $expired = $self->_find_expired_jobs($important_builds, $self->keep_results_in_days,
        $self->keep_important_results_in_days);
    return $expired ? [$expired->all] : [];
}

sub find_jobs_with_expired_logs ($self, $important_builds = undef, $preserved_important_jobs_out = undef) {
    $important_builds //= $self->important_builds;
    my $expired
      = $self->_find_expired_jobs($important_builds, $self->keep_logs_in_days, $self->keep_important_logs_in_days,
        $preserved_important_jobs_out);
    return $expired ? [$expired->search({logs_present => 1})->all] : [];
}

# helper function for cleanup task
sub limit_results_and_logs ($self, $preserved_important_jobs_out = undef) {
    my $important_builds_hash = $self->_important_builds;
    my @important_builds = keys %$important_builds_hash;
    my $expired_jobs = $self->find_jobs_with_expired_results(\@important_builds);
    $_->delete for @$expired_jobs;

    my $config = OpenQA::App->singleton->config;
    my $preserved = $config->{archiving}->{archive_preserved_important_jobs} ? $preserved_important_jobs_out : undef;
    my $jobs_with_expired_logs = $self->find_jobs_with_expired_logs(\@important_builds, $preserved);
    $_->delete_logs for @$jobs_with_expired_logs;
}

sub tags {
    my ($self) = @_;

    my %res;
    if (my $parent = $self->parent) {
        parse_tags_from_comments($parent, \%res);
    }
    parse_tags_from_comments($self, \%res);
    return \%res;
}

sub to_template {
    my ($self) = @_;
    # already has yaml template
    return undef if $self->template;

    # Compile a YAML template from the current state
    my $templates = $self->search_related(
        job_templates => {group_id => $self->id},
        {order_by => 'me.test_suite_id'});

    # Always set the hash of test suites to account for empty groups
    my %group = (scenarios => {}, products => {});

    my %machines;
    my %test_suites;
    # Extract products and tests per architecture
    while (my $template = $templates->next) {
        $group{products}{$template->product->name} = {
            distri => $template->product->distri,
            flavor => $template->product->flavor,
            version => $template->product->version
        };

        my %test_suite = (machine => $template->machine->name);

        $machines{$template->product->arch}{$template->machine->name}++;
        if ($template->prio && $template->prio != $self->default_priority) {
            $test_suite{priority} = $template->prio;
        }

        my $settings = $template->settings_hash;
        $test_suite{settings} = $settings if %$settings;
        my $description = $template->description;
        $test_suite{description} = $description if length $description;

        my $scenarios = $group{scenarios}{$template->product->arch}{$template->product->name};
        push @$scenarios, {$template->test_suite->name => \%test_suite};
        $group{scenarios}{$template->product->arch}{$template->product->name} = $scenarios;
        $test_suites{$template->product->arch}{$template->test_suite->name}++;
    }

    # Split off defaults
    foreach my $arch (sort keys %{$group{scenarios}}) {
        $group{defaults}{$arch}{priority} = $self->default_priority;
        my $default_machine
          = (sort { $machines{$arch}->{$b} <=> $machines{$arch}->{$a} or $b cmp $a } keys %{$machines{$arch}})[0];
        $group{defaults}{$arch}{machine} = $default_machine;

        foreach my $product (sort keys %{$group{scenarios}->{$arch}}) {
            my @scenarios;
            foreach my $test_suite (@{$group{scenarios}->{$arch}->{$product}}) {
                foreach my $name (sort keys %$test_suite) {
                    my $attr = $test_suite->{$name};
                    if ($attr->{machine} eq $default_machine) {
                        delete $attr->{machine} if $test_suites{$arch}{$name} == 1;
                    }
                    if (keys %$attr) {
                        $test_suite->{$name} = $attr;
                        push @scenarios, $test_suite;
                    }
                    else {
                        push @scenarios, $name;
                    }
                }
            }
            $group{scenarios}{$arch}{$product} = \@scenarios;
        }
    }

    return \%group;
}

sub to_yaml {
    my ($self) = @_;
    if ($self->template) {
        return $self->template;
    }
    my $hash = $self->to_template;

    return dump_yaml(string => $hash);
}

sub template_data_from_yaml {
    my ($self, $yaml) = @_;
    my %job_template_names;

    # Add/update job templates from YAML data
    # (create test suites if not already present, fail if referenced machine and product is missing)
    my $yaml_archs = $yaml->{scenarios};
    my $yaml_products = $yaml->{products};
    my $yaml_defaults = $yaml->{defaults};
    foreach my $arch (sort keys %$yaml_archs) {
        my $yaml_products_for_arch = $yaml_archs->{$arch};
        my $yaml_defaults_for_arch = $yaml_defaults->{$arch};
        foreach my $product_name (sort keys %$yaml_products_for_arch) {
            foreach my $spec (@{$yaml_products_for_arch->{$product_name}}) {
                # Get testsuite, machine, prio and job template settings from YAML data
                my $testsuite_name;
                my $job_template_name;
                # Assign defaults
                my $prio = $yaml_defaults_for_arch->{priority};
                my $machine_names = $yaml_defaults_for_arch->{machine};
                my $settings = dclone($yaml_defaults_for_arch->{settings} // {});
                my $description = '';
                if (ref $spec eq 'HASH') {
                    # We only have one key. Asserted by schema
                    $testsuite_name = (keys %$spec)[0];
                    my $attr = $spec->{$testsuite_name};
                    if ($attr->{priority}) {
                        $prio = $attr->{priority};
                    }
                    if ($attr->{machine}) {
                        $machine_names = $attr->{machine};
                    }
                    if (exists $attr->{testsuite}) {
                        $job_template_name = $testsuite_name;
                        $testsuite_name = $attr->{testsuite};
                    }
                    if ($attr->{settings}) {
                        %$settings = (%{$settings // {}}, %{$attr->{settings}});
                    }
                    if (defined $attr->{description}) {
                        $description = $attr->{description};
                    }
                }
                else {
                    $testsuite_name = $spec;
                }

                $machine_names = [$machine_names] if ref($machine_names) ne 'ARRAY';
                foreach my $machine_name (@{$machine_names}) {
                    my $job_template_key
                      = $arch . $product_name . $machine_name . ($testsuite_name // '') . ($job_template_name // '');
                    die "Job template name '"
                      . ($job_template_name // $testsuite_name)
                      . "' is defined more than once. "
                      . "Use a unique name and specify 'testsuite' to re-use test suites in multiple scenarios.\n"
                      if $job_template_names{$job_template_key};
                    $job_template_names{$job_template_key} = {
                        prio => $prio,
                        machine_name => $machine_name,
                        arch => $arch,
                        product_name => $product_name,
                        product_spec => $yaml_products->{$product_name},
                        job_template_name => $job_template_name,
                        testsuite_name => $testsuite_name,
                        settings => $settings,
                        length $description ? (description => $description) : (),
                    };
                }
            }
        }
    }

    return \%job_template_names;
}

sub expand_yaml {
    my ($self, $job_template_names) = @_;
    my $result = {};
    foreach my $job_template_key (sort keys %$job_template_names) {
        my $spec = $job_template_names->{$job_template_key};
        my $scenario = {
            $spec->{job_template_name} // $spec->{testsuite_name} => {
                machine => $spec->{machine_name},
                priority => $spec->{prio},
                settings => $spec->{settings},
                length $spec->{description} ? (description => $spec->{description}) : (),
            }};
        push @{$result->{scenarios}->{$spec->{arch}}->{$spec->{product_name}}}, {%$scenario,};
        $result->{products}->{$spec->{product_name}} = $spec->{product_spec};
    }
    return dump_yaml(string => $result);
}

sub text_diff {
    my ($self, $new) = @_;
    my $changes;
    if ($self->template && $self->template ne $new) {
        $changes = "\n" . diff \$self->template, \$new;
        # Remove the warning about new lines. We don't require that!
        $changes =~ s/\\ No newline at end of file\n//;
        # Remove leading and trailing whitespace
        $changes =~ s/^\s+|\s+$//g;
    }
    return $changes;
}

1;
