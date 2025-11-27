# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::ScheduledProduct::Limit;
use Mojo::Base 'OpenQA::Task::Table::Limit';

has task_name => 'limit_scheduled_products';
has table => 'ScheduledProducts';

1;
