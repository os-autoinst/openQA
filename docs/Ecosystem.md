<a id="ecosystem"></a>

# Ecosystem

## Introduction

openQA is more than a single tool. The core is two repositories,
[openQA](https://github.com/os-autoinst/openQA) (web UI, scheduler, worker)
and [os-autoinst](https://github.com/os-autoinst/os-autoinst) (the backend
that runs the system under test). The ecosystem is everything built around
them: the many other projects in the
[os-autoinst organization](https://github.com/os-autoinst), public instances,
learning resources, and a community. This page is a discovery guide for users
and a place for contributors to add their instance, project, blog, or video
with a pull request.

## Related projects

Beyond the core repos, the
[os-autoinst organization](https://github.com/os-autoinst) hosts many more
projects, e.g. the test distributions and needles:

- [os-autoinst-distri-opensuse](https://github.com/os-autoinst/os-autoinst-distri-opensuse):
  the openSUSE and SLE tests, conducted on
  [openqa.opensuse.org](https://openqa.opensuse.org).
- [os-autoinst-distri-example](https://github.com/os-autoinst/os-autoinst-distri-example):
  a template to start writing tests for a new operating system.
- [os-autoinst-needles-opensuse](https://github.com/os-autoinst/os-autoinst-needles-opensuse):
  reference images not already included in the test distribution.

The list is intentionally short: the organization contains many more projects,
so browse it directly rather than enumerating them here, which would quickly
go stale.

Third-party tools live outside the organization, e.g.
[Haystack](https://gitlab.gnome.org/jwharm/Haystack)
([Flathub](https://flathub.org/en/apps/app.drey.Haystack)), a GNOME app to
edit openQA needles.

## Public instances

Anyone can run an openQA instance, so this is a non-exhaustive list of known
public instances, not an authoritative registry. openQA is one part of each
project's test infrastructure, not necessarily its primary quality gateway.
Operators who prefer not to be listed can request removal.

- [openqa.opensuse.org](https://openqa.opensuse.org): openSUSE.
- [openqa.suse.de](https://openqa.suse.de): SUSE SLE (private).
- [Fedora](https://openqa.fedoraproject.org/): Fedora.
- [AlmaLinux](http://openqa.almalinux.org/): AlmaLinux.
- [Debian](https://openqa.debian.net/): Debian.
- [Qubes OS](https://openqa.qubes-os.org/): Qubes OS.
- [Endless OS](https://openqa.endlessm.com/): Endless OS.
- [GNOME](https://openqa.gnome.org): the GNOME project.
- KDE: see the
  [KDE blog post on openQA testing in KDE Linux](https://blogs.kde.org/2026-07-13/openqa-testing-in-kde-linux/).
- openSUSE KDE contributors:
  [group 23](https://openqa.opensuse.org/group_overview/23).
- openSUSE GNOME contributors:
  [group 35](https://openqa.opensuse.org/group_overview/35).
- OBS developers:
  [parent group 7](https://openqa.opensuse.org/parent_group_overview/7#grouped_by_build).
- wicked developers:
  [wicked-ci](https://gitlab.suse.de/wicked-maintainers/wicked-ci#openqa).
- openQA-in-openQA (the team's own tests):
  [group 24](https://openqa.opensuse.org/group_overview/24).

See also the
[openSUSE:OpenQA/Partners](https://en.opensuse.org/openSUSE:OpenQA/Partners)
page.

## Learning resources

- [openqa-bites](https://openqa-bites.github.io/): stories and tutorials from
  an openQA developer.
- [Liv's blog](https://liv.pink/): guides and hints from an openQA developer.
- [EuroLinux on openQA](https://en.euro-linux.com/blog/openqa-or-how-we-test-eurolinux/):
  how EuroLinux tests with openQA.
- [Codethink on automated Linux kernel testing](https://www.codethink.co.uk/articles/2021/automated-linux-kernel-testing/).
- [SUSE QE Tools Workshop](https://youtube.com/playlist?list=PL6TdzZgl22k7GD62L292tn3dBTg1JPmVF):
  a playlist covering many topics.
- [Conference presentations on media.ccc.de](https://media.ccc.de/search/?q=openQA).
- [Various videos on YouTube](https://www.youtube.com/results?search_query=openQA).
- [Linux Inlaws podcast featuring openQA](https://archive.org/download/LI_S02E16_OpenQA__0D80/LI_S02E16_OpenQA_.mp3).
- [Testing in a Box: Streamlining Embedded Systems Testing](https://www.youtube.com/watch?v=Q2Y1YQ8V5gk).

## Community and contributing

- The [openQAv3 project](https://progress.opensuse.org/projects/openqav3) in
  openSUSE's project management tool coordinates the development roadmap.
- The QA testing monthly call:
  [GNOME QA testing monthly call](https://gitlab.gnome.org/GNOME/openqa-tests/-/wikis/QA-testing-monthly-call).
- The official openSUSE presence on
  [Reddit](https://www.reddit.com/r/opensuse/) and openQA on
  [X/Twitter by openQAhq](https://twitter.com/openQAhq).

If you are contributing to openQA by running an instance, writing a tool, a
post, a video, or a podcast, add a link to the relevant section above with a
pull request to
[`docs/Ecosystem.md`](https://github.com/os-autoinst/openQA/blob/master/docs/Ecosystem.md).
