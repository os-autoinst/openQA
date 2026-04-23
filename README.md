image:https://codecov.io/gh/os-autoinst/openQA/branch/master/graph/badge.svg[link=https://codecov.io/gh/os-autoinst/openQA] image:https://circleci.com/gh/os-autoinst/openQA/tree/master.svg?style=svg["CircleCI", link="https://circleci.com/gh/os-autoinst/openQA/tree/master"] image:https://openqa.opensuse.org/tests/latest/badge?arch=x86_64&distri=openqa&flavor=dev&test=openqa_install%2Bpublish&version=Tumbleweed[link="https://openqa.opensuse.org/tests/latest?arch=x86_64&distri=openqa&flavor=dev&machine=64bit-2G&test=openqa_install%2Bpublish&version=Tumbleweed"]

openQA is a testing framework that allows you to test GUI applications on one
hand and bootloader and kernel on the other. In both cases, it is difficult to
script tests and verify the output. Output can be a popup window or it can be
an error in early boot even before init is executed.

Therefore openQA runs virtual machines and closely monitors their state and
runs tests on them.

The testing framework can be divided in two parts. The one that is hosted in
this repository contains the web frontend and management logic (test
scheduling, management, high-level API, …)

The other part that you need to run openQA is the OS-autoinst test engine that
is hosted in a separate [repository](https://github.com/os-autoinst/os-autoinst).

# Getting started

The project's information is organized into four basic documents. As a first
step, read the [Starter Guide](docs/GettingStarted.md) and then, if
needed, proceed to the [Installation Guide](docs/Installing.md).

For users of the openQA web interface or the REST API consult
[Users Guide](docs/UsersGuide.md).

If you are interested in writing tests using openQA read the
[Tests Developer Guide](docs/WritingTests.md).

Try out running tests with openQA in a browser in
[our Codespace](https://codespaces.new/os-autoinst/openQA?quickstart=1).
See also: [GitHub Codespaces documentation](https://docs.github.com/en/codespaces)

See [openQA in a browser](https://open.qa/docs/#_openqa_in_a_browser) for
documentation on how to use it.

# Contributing



If you are interested in contributing to openQA itself, check the
[Developer Guide](docs/Contributing.md), write your code and send a
pull request ;-)



## Issue trackers and support



Our main issue tracker is at [openQAv3 project](https://progress.opensuse.org/projects/openqav3) in openSUSE's project management
tool. This Redmine instance is used to coordinate the main development
effort organizing the existing issues (bugs and desired features) into
'target versions'.

Find contact details and meet developers over
[our contact page](http://open.qa/contact/).

# Releases

openQA is developed on a continuous base where every commit in the git master
branch is considered stable and a valid and installable version. The old tags
on github are therefore misleading.

# License

All code is licensed under [GPL-2-or-later](COPYING) unless stated otherwise
in particular files. This does **not** apply to code found in the
`assets/3rdparty` directory. It contains third-party code and the relevant
licenses can be found in the root directory of this code repository.
