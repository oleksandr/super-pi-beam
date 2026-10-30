# Deploying Super-Pi-BEAM

Super-Pi ships as an Elixir **release**: one self-contained directory started with `bin/super_pi start`. It needs a PostgreSQL for more than one node, and an Erlang cookie and distribution ports between the nodes.

| Target | Files | Discovery strategy |
|---|---|---|
| Docker / compose | `Dockerfile`, `docker-compose.yml` | `dnspoll` (service name) |
| VMs, Proxmox | `vm/super-pi.service`, `vm/super-pi.env.example` | `epmd` (static list) or `dnspoll` |
| Kubernetes | `kubernetes/super-pi.yaml` | `kubernetes_dns` (headless Service) |

All three were run for real: the compose file with two nodes and PostgreSQL, the Kubernetes manifests on a local k3s with three pods (and a pod replaced), and the release started by hand. The systemd unit was not run on a VM.

## Build

```bash
docker build -t super-pi .                          # image, from the repository root
MIX_ENV=prod mix release super_pi                   # or a release directory: _build/prod/rel/super_pi
```

## Steps for any target

1. **PostgreSQL.** A separate instance; see *Production PostgreSQL* in the README (`DATABASE_URL`, `SUPER_PI_DB_SSL`).
2. **Migrate, before the new version takes traffic.** A release does not migrate at boot:
   `bin/super_pi eval "SuperPi.Release.migrate()"` (a Job in Kubernetes, the `migrate` service in compose).
3. **Start the nodes** with the settings below.
4. **Check:** `GET /ready` (200 while the node accepts work), `GET /health` (liveness), `GET /cluster` (members and machines per node; needs the token).

## Settings

| Variable | Purpose |
|---|---|
| `SUPER_PI_STORAGE_BACKEND=postgres`, `DATABASE_URL`, `SUPER_PI_DB_SSL` | storage |
| `SUPER_PI_GATEWAY=true`, `SUPER_PI_GATEWAY_BIND`, `SUPER_PI_GATEWAY_PORT`, `SUPER_PI_GATEWAY_TOKEN` | the HTTP gateway (a non-loopback bind needs a token) |
| `SUPER_PI_CLUSTER_STRATEGY` and the strategy's variables | node discovery (see the README, *Multi-Node Cluster*) |
| `RELEASE_COOKIE` | shared secret between the nodes (required for a cluster) |
| `RELEASE_NODE`, `SUPER_PI_NODE_HOST` | node name and address (set by `rel/env.sh.eex`: the IP for `dnspoll` and `kubernetes_dns`) |
| `SUPER_PI_DIST_PORT_MIN` / `_MAX` | distribution port range (default 9100 to 9155); open it between nodes, with epmd on 4369 |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | trace export |
| `GEMINI_API_KEY` | the model provider |

## Rolling deploys

On SIGTERM a node stops taking new turns, finishes the running ones (`drain_timeout_ms`, default 30 s), and stops. Give the platform more time than that: `stop_grace_period: 40s` (compose), `TimeoutStopSec=45` (systemd), `terminationGracePeriodSeconds: 45` (Kubernetes). The readiness probe is `/ready`, so a draining node leaves the load balancer first. A turn that does not finish in time resumes on another node.

Migrations must stay backward compatible with the previous version, because old and new nodes run side by side during a rollout.

## Workspaces

Tools act on the local disk of the node that runs the conversation. For a cluster use a `shared` workspace (a directory every node mounts: NFS, CephFS, a ReadWriteMany volume), or `scratch`/`none` with artifacts. See the README, *Workspaces and Artifacts*.

## Not covered

TLS termination for the gateway (put a reverse proxy or ingress in front), secrets management beyond the examples, Helm chart, horizontal autoscaling, a shared-volume example for Kubernetes beyond the commented lines.
