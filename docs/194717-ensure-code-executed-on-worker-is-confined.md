# 194717 Ensure code executed on the worker is confined
Issue: https://progress.opensuse.org/issues/194717

## Summary

Test modules run as Perl code inside the `isotovideo` process on the **host**, not inside the VM.
That means a test module can read files, write to the filesystem, or make network requests as the worker OS user — even on a production server with a dedicated account.

This document describes what was investigated, what works, and what still needs to be done.

## Investigation

To demonstrate the attack surface I wrote a test module (`tests/install/explore.pm`) that uses standard testapi calls (`script_run`, `upload_logs`) alongside direct Perl code to do sensitive things from inside the worker process on the host side.
TThis covers the main ways a malicious test module could exploit the worker: testapi calls that run commands in the VM but also give access to the host process, direct host file reads, and leaking files via `upload_logs` to the web UI.
Other attack vectors acknowledged but not demonstrated: external code pulled in via container images or git repos during a job, and arbitrary commands passed through job variables or openQA settings.

I ran the same test module against a confined and an unconfined worker to compare results.

### systemd hardening — tested and working

I added standard systemd hardening directives to the worker unit. This solution seems to be the less efortless with great value return, which should be applied first .
The key confirmed results:

- Writing to `/etc` fails with `Read-only file system` and this confirms systemd is enforcing the restriction at the kernel level, not just relying on normal file permissions.
- Writing to the home directory also fails the same way once `ProtectHome` is active.
- Other users' processes are hidden in `/proc`. Processes running as the same user are still visible (this is expected behavior!).

The full set of directives tested:

```ini
ProtectSystem=strict
ProtectHome=yes
ProtectProc=invisible
NoNewPrivileges=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectKernelLogs=yes
ProtectControlGroups=yes
ProtectClock=yes
ProtectHostname=yes
RestrictSUIDSGID=yes
RestrictRealtime=yes
LockPersonality=yes
```

Several directives cannot be used because they break QEMU:

| Directive | Why excluded |
|---|---|
| `MemoryDenyWriteExecute=yes` | QEMU needs to write and execute memory for its JIT compiler |
| `PrivateDevices=yes` | Would remove `/dev/kvm` access |
| `PrivateNetwork=yes` | Worker needs network to reach the WebUI and cache service |
| `RestrictNamespaces=yes` | QEMU networking needs this |
| `SystemCallFilter=` | QEMU uses too many system calls to filter safely |

### AppArmor — gaps identified, follow-up needed

I looked at the existing profile (`/etc/apparmor.d/usr.share.openqa.script.worker`) and mainly there are alrady several rules but found two gaps:

1. The profile allows reading `/etc/openqa/client.conf` — any test module can read the worker API key.
2. `isotovideo` runs with the same permissions as the worker daemon — there is no separation between the two.

I drafted a tighter sub-profile for `isotovideo` that would close these gaps, but could not test it locally because the worker in my dev setup runs as a user session service, which causes conflicts with AppArmor that do not exist on production. The approach is valid and needs to be tested on a production worker.

## Known Limitations

- **Same-user `/proc` visibility:** `ProtectProc=invisible` hides processes of other users but not processes running as the same user. If all openQA services share one account, a test module can still read their environment variables.
- **Network not yet restricted:** A test module can still make outbound connections. Adding network restrictions depends on various factors which I couldnt determine in a timebox. I could not come up with any one solid idea.                             


## Proposal and followup

- [ ] Add a test module in openqa-to-openqa for a list of confined operations
- [ ] Add systemd hardening directives to the production worker unit
      - use one dedicate worker slot for starters
      - need to test among a variety of test cases
- [ ] Test the AppArmor `isotovideo` sub-profile on production in complain mode
      - Already mostly in place

## Out of Scope

- **Network restriction** — as mentioned above
- **Containers, lxc, cgroups/namespaces** — I assessed these as confinement options. They considered the industry standard in a review of other tools but quite complex for a timeboxed experiment. Compared to systemd and AppArmor solutions, the effort is much higher for a similar result on a worker.
- **SELinux** — production uses AppArmor; switching would need a follow up once we switch to it
- **Syscall filtering** — needs detailed profiling of QEMU, high risk of breakage;
- **Code scanning** — Semgrep with custom rules could flag dangerous patterns in test modules; out of scope here but worth a separate investigation