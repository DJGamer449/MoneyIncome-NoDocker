# ExpressVPN at High Scale (up to ~1000 containers)

This repository now includes a dedicated lightweight ExpressVPN container runtime:

- `Dockerfile.expressvpn`
- `docker/entrypoint-expressvpn.sh`
- `docker/expressvpn-healthcheck.sh`
- `docker-compose.expressvpn-scale.yml`

## Key optimization choices

1. **glibc slim base over Alpine**
   - ExpressVPN Linux binaries are glibc-oriented.
   - `debian:bookworm-slim` is compact and avoids Alpine musl compatibility overhead.

2. **Low-overhead runtime settings**
   - `MALLOC_ARENA_MAX=2` to reduce allocator memory bloat.
   - tiny healthcheck interval + short timeout to limit CPU overhead.
   - `tini` as PID 1 to prevent zombie processes.

3. **Container resource controls**
   - `read_only` root filesystem.
   - `tmpfs` for write-heavy locations to minimize disk IO contention.
   - `pids_limit`, `mem_limit`, and `cpus` caps for predictable density.

4. **Crash/log cleanup during build**
   - Removes stale crash dumps and transient logs from bundled ExpressVPN directory.

## Build

```bash
docker build -f Dockerfile.expressvpn -t local/expressvpn-scale:latest .
```

## Run (single)

```bash
docker run -d \
  --name expressvpn-1 \
  --cap-add=NET_ADMIN \
  --device /dev/net/tun:/dev/net/tun \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,size=32m \
  --tmpfs /opt/expressvpn/var:rw,noexec,nosuid,size=64m \
  -e MALLOC_ARENA_MAX=2 \
  --pids-limit 64 \
  --memory 192m \
  --cpus 0.35 \
  local/expressvpn-scale:latest
```

## Run (compose scale)

```bash
docker compose -f docker-compose.expressvpn-scale.yml up -d --scale expressvpn=1000
```

## Host-level tuning for 1000 containers

Recommended before very high density tests:

```bash
sudo sysctl -w fs.file-max=2000000
sudo sysctl -w fs.nr_open=4000000
sudo sysctl -w net.core.somaxconn=65535
sudo sysctl -w net.netfilter.nf_conntrack_max=1048576
sudo sysctl -w net.ipv4.ip_local_port_range='1024 65535'
```

Also ensure Docker daemon uses `cgroupfs`/`systemd` consistently and monitor conntrack usage.
