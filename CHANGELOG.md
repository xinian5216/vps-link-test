# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-02

First release. A single-file Bash tool that measures the link between two Linux
VPSes and exits.

### Added

**Core**

- `vpslink.sh` as a single self-contained script, runnable with
  `bash <(curl -fsSL …/vpslink.sh)`.
- Plain-ANSI TUI with a colour auto-detect: colours are enabled only when stdout
  is a TTY, `TERM` is set and not `dumb`, and neither `NO_COLOR` nor
  `--no-color` is present. Piped output never contains escape codes.
- CLI flags `--help`, `--version`, `--no-color`.
- Menu: A mode, B mode, environment information, exit. No dialog, no whiptail.
- Environment screen: distribution, kernel, architecture, package manager,
  public and local addresses, and per-command availability with its origin
  (pre-existing / installed by this run / missing).

**Distribution support**

- Debian, Ubuntu, AlmaLinux, Rocky Linux and CentOS Stream, resolved from
  `/etc/os-release` (`ID`, then `ID_LIKE` for derivatives).
- Package manager auto-detection across `apt`, `dnf` and `yum`.
- Unsupported distributions exit with a readable message and install nothing.

**Dependencies**

- Detects `curl`, `ping`, `iperf3`, `mtr`, `jq`, `ss` and `timeout`, and installs
  only what is missing, with package de-duplication.
- Snapshots which commands already existed before the run, so the origin of each
  command stays traceable.
- Refuses to replace a package that is already installed: such a command is
  reported as unavailable instead.
- `sudo -n` only, with a readable message when privilege escalation is missing.
- Optional removal at exit, limited to packages that did not exist before this
  run and were installed by this run, only after an explicit confirmation, and
  using `remove` rather than `autoremove`.
- No upgrade, no `dist-upgrade`, no `autoremove`, no repository change.

**A mode**

- Random TCP port in `30000-50000`, verified free against TCP and UDP listeners
  with `ss`, regenerated on conflict.
- `iperf3 -s -1 -p PORT` one-off server; a fresh one is started for the second
  session.
- Round 1 waits up to 600 s, round 2 up to 180 s, enforced by a hard-deadline
  loop; `--idle-timeout` is added as a second layer when iperf3 advertises it.
- The bound address families are read back from `ss`, so IPv4-only, IPv6-only
  and dual-stack hosts are reported truthfully.
- Public IP detection with independent fallback services, plus a manual prompt
  (and a local-address hint) when detection fails.
- `VPSLINK_SKIP_IP_DETECT=1` escape hatch for offline testing.

**B mode**

- Fixed order: connectivity preparation, ping, MTR, `B -> A` throughput,
  `A -> B` throughput, analyze, report.
- IPv4 literal, IPv6 literal or hostname targets; an explicit family choice when
  a hostname resolves to both.
- `ping -n -c 20 -W 2` parsed under `LC_ALL=C` (with `-6` tried first for IPv6
  targets).
- `mtr -r -c 20` with `--json`, falling back to `-j`, falling back to the plain
  text report, with a bounded `sudo -n` retry for hosts that restrict raw
  sockets.
- `iperf3 -c TARGET -p PORT -t 10 -O 2 -J` and the same with `-R`, parsed from
  JSON, with graceful degradation when `-O` is not advertised.
- Single TCP stream, two separate directions. No `-P 4`, no `--bidir`, no UDP,
  no zerocopy.

**Parsers and report**

- `parse_ping_file`, `parse_iperf3_file` and `parse_mtr_file`: pure functions of
  an output file that print `key=value` lines.
- Report of objective data: target, latency, route, observed TCP throughput and
  retransmits.
- `RTT variation` instead of claiming `mdev` is jitter; observed throughput is
  always labelled as a single-stream measurement and never as port bandwidth.
- Transparent, re-derivable stability rules. No composite 0-100 score and no
  judging a route on absolute RTT alone.
- Route loss taken from the target row only; intermediate hop ICMP loss is never
  reported as link loss.
- Renders for every combination of missing measurements.

**Safety and cleanup**

- `cleanup()` on `EXIT`, `INT` and `TERM`, where INT/TERM exit immediately so the
  script never resumes after an interruption.
- Scratch directory `/tmp/vps-link-test-XXXXXXXX/` from `mktemp -d`, deleted only
  when it carries this run's ownership marker, is a real directory and matches
  the `vps-link-test-` prefix.
- Only the `iperf3` PID this run started is ever signalled.
- No pkill, no killall, no touching of an existing iperf3 instance.

**Testing and CI**

- `tests/test_parsers.sh` with 87 assertions, driven entirely offline.
- Fixtures for ping success / partial loss / total loss, iperf3 normal, reverse
  and error JSON, mtr JSON and the mtr plain-text fallback.
- GitHub Actions with five jobs: `bash -n`, ShellCheck at `--severity=style`,
  parser fixture tests, a non-interactive smoke test that also asserts no ANSI
  escape codes leak, and a production-safety scan that fails the build if the
  source ever contains a system-modifying command.

[0.1.0]: https://github.com/xinian5216/vps-link-test/releases/tag/v0.1.0
