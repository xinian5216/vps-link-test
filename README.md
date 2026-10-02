# vps-link-test

A lightweight **VPS ↔ VPS network link test** tool.

Two Linux VPS run the same single-file Bash script. One side picks **A mode**
and becomes a temporary `iperf3` server, the other picks **B mode**, points at
A's address and temporary port, and automatically runs the common link tests
before printing a short, readable report.

The project is intentionally **small and accurate**. It is *not* a VPS
benchmark suite, *not* a monitoring platform and *not* a Web admin console.

> **Status: under construction.** See the
> [issue tracker](https://github.com/xinian5216/vps-link-test/issues) for what
> has landed and what is next. The initial skeleton only prints the menu and
> environment information; modes A and B are being built up in separate pull
> requests.

## Run it

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xinian5216/vps-link-test/main/vpslink.sh)
```

## What v0.1 will do

- A mode: temporary one-off `iperf3` server on a random high port, accepting
  two sessions (`B → A` and `A → B`).
- B mode: ordered test sequence of ping, MTR, two TCP throughput runs, then a
  report.
- Report of observed data only: RTT min/avg/max, RTT variation, packet loss,
  hop count, target loss, observed TCP throughput and TCP retransmits.
- Automatic, hard-deadlined cleanup of every process, file and PID the run
  created.

## Deliberately not in v0.1

Speedtest, Geekbench, CPU/RAM/disk benchmarks, UDP benchmarks, BGP/ASN/GeoIP
databases, Web UI, database, accounts, daemon, systemd service, scheduled
tasks, SSH remote control, central coordinator, telemetry.

## Supported systems

Debian, Ubuntu, AlmaLinux, Rocky Linux, CentOS Stream. Package managers are
auto-detected among `apt`, `dnf` and `yum`.

## Documentation

- [CHANGELOG.md](CHANGELOG.md)
- [Issues](https://github.com/xinian5216/vps-link-test/issues)

## License

[MIT](LICENSE)
