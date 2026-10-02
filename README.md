# vps-link-test

A lightweight **VPS ↔ VPS network link test** tool.

Two Linux VPS run the *same* single-file Bash script. One side picks **A mode**
and becomes a temporary `iperf3` server; the other picks **B mode**, points at
A's address and temporary port, runs the common link tests in a fixed order and
prints a short, readable report.

The project is deliberately **small and accurate**. It is *not* a VPS benchmark
suite, *not* a monitoring platform, *not* a Web admin console. Test, report,
exit.

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xinian5216/vps-link-test/main/vpslink.sh)
```

That is the entire install story. One file, no daemon, no systemd unit, no
scheduled task, no telemetry, nothing left running.

---

## Quick start

On **VPS A** (the one that will wait):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xinian5216/vps-link-test/main/vpslink.sh)
# choose 1  (A mode)
```

You get:

```text
A mode ready

IPv4:
203.0.113.4

IPv6:
2001:db8::4

Port:
43821
```

On **VPS B** (the one that tests):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xinian5216/vps-link-test/main/vpslink.sh)
# choose 2  (B mode)
# Address: 203.0.113.4
# Port:    43821
```

B runs the sequence and prints the report. A mode finishes by itself once both
sessions are done, or after its wait limit expires.

---

## How a test runs

```text
Step 1  Connectivity preparation   resolve A, pick the address family
Step 2  Ping                       ~20 echo requests
Step 3  MTR                        ~20 cycles
Step 4  TCP throughput B -> A      10 s, single stream
Step 5  TCP throughput A -> B      10 s, single stream, -R
Step 6  Analyze
Step 7  Report
```

### A mode

- Detects its public IPv4 and IPv6 addresses.
- Picks a **random** TCP port in `30000-50000` and verifies with `ss` that
  nothing already listens on it (TCP *and* UDP). On conflict it picks another
  one — an existing listener is never taken over.
- Starts `iperf3 -s -1 -p PORT`, i.e. a one-off server that accepts exactly
  **one** client session and then exits.
- After session 1 finishes it starts a **fresh** one-off server for session 2.
- Round 1 waits up to 10 minutes, round 2 up to 3 minutes. Every wait has a
  hard deadline; nothing can hang forever.
- `--idle-timeout` is passed when the installed iperf3 advertises it, so the
  server also self-terminates if no client ever appears.
- Which address families actually got bound is read back from `ss`, so an
  IPv4-only, IPv6-only or dual-stack host is reported truthfully rather than
  assumed.
- If public IP detection fails (a very common reason: outbound HTTP blocked),
  you are simply asked to type the address, with your machine's own local
  address shown as a hint.

### B mode

- Accepts an IPv4 address, an IPv6 address, or a hostname.
- If a hostname resolves to both `A` and `AAAA` records, you choose the
  protocol, and the report states which one was used.
- Every external command is wrapped in `timeout`.
- Any single step may fail without aborting the run.

---

## The report

```text
========================================
            VPS Link Test
========================================

Target
  Address          203.0.113.4
  Protocol         IPv4

Latency
  Min              38.4 ms
  Avg              40.7 ms
  Max              46.2 ms
  RTT variation    1.8 ms
  Packet loss      0.0 %

Route
  Hops             11
  Target loss      0.0 %

TCP Throughput
  B -> A           382.4 Mbps
  A -> B           517.8 Mbps

TCP Retransmits
  B -> A           12
  A -> B           7

----------------------------------------

Result

  Connectivity     Normal
  Stability        Good
  Packet loss      None

A -> B throughput is approximately
  35% higher than B -> A.

----------------------------------------

Observed TCP throughput is a single TCP stream over one direction.
It is not the port bandwidth of either VPS.
RTT variation is the ping mdev value. It is not a strict jitter
measurement.
Route loss is taken from the target only. Intermediate hops are
not counted, because they often rate limit ICMP.

========================================
```

### Reading the fields

| field | meaning | what it is not |
| --- | --- | --- |
| `Min` / `Avg` / `Max` | ping round-trip time | not a statement about the route's quality |
| `RTT variation` | the `mdev` from iputils ping | **not** strict jitter |
| `Packet loss` | from the ping summary line only | not taken from MTR |
| `Hops` | number of MTR hops seen | not a traceroute dump |
| `Target loss` | loss at the **target** | not the loss of intermediate hops |
| `TCP Throughput` | observed, one TCP stream, one direction | **not** the VPS port bandwidth |
| `TCP Retransmits` | TCP retransmissions the sender reported | not a packet-loss measure |

### The verdict rules, written down

`Stability` is derived, not vibes:

| condition | verdict |
| --- | --- |
| packet loss > 0 | `Packet loss detected` |
| loss 0 and variation > 50 ms | `Unstable` |
| loss 0 and variation > 5 ms | `Normal` |
| loss 0 and variation ≤ 5 ms | `Good` |
| ping unavailable | `Unknown` |

`Connectivity` is `Normal` when the target answered ping **or** a TCP test
succeeded, and `Failed` only when neither did.

`A -> B throughput is approximately 35% higher than B -> A` uses the *smaller*
direction as the base: `517.8 / 382.4 - 1 = 35%`. Both directions within 10 %
are reported as "within 10% of each other" rather than inventing a winner.

There is **no composite 0-100 score**, and a route is **never** judged on
absolute RTT alone — a transcontinental link naturally has a high RTT and that
is not a fault.

### Why intermediate MTR hops are ignored

```text
Hop 5 = 50% loss
Hop 6 = 0%
Target = 0%
```

must not produce "severe packet loss at hop 5". Many routers rate-limit the
ICMP they answer to traceroute, which looks exactly like loss. Link loss is
therefore judged from the **target** ping and the **target** MTR row only.

---

## Supported systems

| distribution | package manager |
| --- | --- |
| Debian | `apt` |
| Ubuntu | `apt` |
| AlmaLinux | `dnf` |
| Rocky Linux | `dnf` |
| CentOS Stream | `yum` or `dnf` |

The manager is auto-detected from `/etc/os-release`, so common derivatives
(Linux Mint, Oracle Linux, …) work too. Anything else exits immediately with a
clear message and installs nothing.

---

## Dependencies

Detected before the run starts:

`curl` · `ping` · `iperf3` · `mtr` · `jq` · `ss` · `timeout`

Missing ones are listed, and you are asked once whether to install them. You can
answer no — the affected steps are then reported as unavailable and the rest of
the test still runs.

| command | Debian / Ubuntu | RHEL family |
| --- | --- | --- |
| `curl` | `curl` | `curl` |
| `ping` | `iputils-ping` | `iputils` |
| `iperf3` | `iperf3` | `iperf3` |
| `mtr` | `mtr` | `mtr` |
| `jq` | `jq` | `jq` |
| `ss` | `iproute2` | `iproute` |
| `timeout` | `coreutils`, never installed | `coreutils`, never installed |

### What the dependency handling never does

- never **upgrades** anything (`apt upgrade`, `dist-upgrade`, `dnf upgrade`,
  `yum update` are not in the source)
- never runs `autoremove`
- never adds or edits a repository or `sources.list`
- never replaces a package that is already installed. If the package is present
  but the command is missing, the package is left completely alone and the
  command is reported as unavailable.
- the only `apt-get update` in the file is a single retry after an install has
  already **failed** (missing package index on a fresh image), and only if the
  package metadata is actually missing
- at exit you may remove what this run added, but only packages that did **not**
  exist before this run, only after an explicit `y`, and with `remove` — never
  `autoremove`
- `timeout` is part of coreutils on every supported distribution and is never
  installed or replaced

---

## Firewalls and security groups

The script **never** touches iptables, nftables, UFW or firewalld. It does not
flush rules and does not change default policies. A's temporary port has to be
reachable from B — cloud providers do not let a guest open its own inbound
rules.

If B cannot connect, the report tells you where to look:

```text
Possible causes:

- Local firewall
- Cloud security group
- Provider ACL
- NAT / CGNAT
- Incorrect address or port
```

If you must narrow one temporarily, allow **inbound TCP** on the printed port
from B's address only, for the duration of the test, and remove it afterwards.
Opening the `iperf3` default port `5201` permanently is a bad habit.

---

## Safety and cleanup

This script is expected to run on **real production VPSes**.

- `cleanup()` is bound to `EXIT`, `INT` and `TERM`. INT/TERM exit immediately so
  the script never resumes with a deleted working directory, and the EXIT trap
  runs cleanup exactly once.
- All scratch files live in `/tmp/vps-link-test-XXXXXXXX/`, created with
  `mktemp -d` and marked with `.vpslink-owned`.
- A directory is deleted only if it contains that marker, is a real directory
  (not a symlink), and matches the `vps-link-test-` prefix.
- Only the `iperf3` PID **this run started** is ever signalled. There is no
  `pkill`, no `killall`, and no touching of another iperf3 instance.
- CI contains a job that fails the build if the source ever contains a command
  that reboots the machine, restarts a service, edits sshd, sysctl, DNS, routes
  or interfaces, touches a firewall, or kills unrelated processes.

The script does **not**: reboot, restart sshd, edit `sshd_config`, change
`sysctl`, touch DNS or routing, modify interfaces, change proxies, touch an
existing iperf3 service, or occupy a port that is already in use.

---

## Development

```bash
bash -n vpslink.sh                                        # syntax
shellcheck --severity=style vpslink.sh tests/test_parsers.sh
bash tests/test_parsers.sh                                # 87 assertions, offline
```

The parsers are pure functions of a file, so they are unit tested from
`tests/fixtures` without running ping, mtr, iperf3 or hitting the network.

```text
vps-link-test/
├── vpslink.sh
├── README.md
├── CHANGELOG.md
├── LICENSE
├── tests/
│   ├── test_parsers.sh
│   └── fixtures/
└── .github/
    └── workflows/
        └── ci.yml
```

CI runs five jobs: syntax, ShellCheck, parser fixture tests, a non-interactive
smoke test, and the production-safety scan. It never starts a server and never
measures throughput.

---

## v0.1 does not include

Speedtest · Geekbench · CPU benchmark · RAM benchmark · disk benchmark · UDP
benchmark · BGP analysis · ASN database · GeoIP database · Web UI · database ·
account system · daemon · systemd service · scheduled task · SSH remote control ·
central coordinator · telemetry · composite network score

Those may come later, one issue at a time, and only with a clear reason.

## License

[MIT](LICENSE)
