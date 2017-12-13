# Copyright (C) 2017 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::Parser::Result::LTP::Test;
use Mojo::Base 'OpenQA::Parser::Result';

has environment => sub { OpenQA::Parser::Result::LTP::Environment->new() };
has test        => sub { OpenQA::Parser::Result::LTP::SubTest->new() };
has [qw(status test_fqn)];

# Additional data structure - they get mapped automatically
# no need to override here

{
    package OpenQA::Parser::Result::LTP::SubTest;
    use Mojo::Base 'OpenQA::Parser::Result';

    has [qw(log duration result)];
}

{
    package OpenQA::Parser::Result::LTP::Environment;
    use Mojo::Base 'OpenQA::Parser::Result';

    has [qw(gcc product revision kernel ltp_version harness libc arch)];
}

1;
