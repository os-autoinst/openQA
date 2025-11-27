# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::AuditEvents::Limit;
use Mojo::Base 'OpenQA::Task::Table::Limit';

has task_name => 'limit_audit_events';
has table => 'AuditEvents';

1;
