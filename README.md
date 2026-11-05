# platform

Everything that runs in the Docker Desktop cluster (`192.168.68.57`, context `docker-desktop`) except the applications: operators, data services, monitoring and Argo CD. The apps' manifests live in their own repos, like [importer](https://github.com/c88lopez/importer).

Until this repo existed, most of this was installed by hand and lived only in the cluster. Each file here was exported from the running cluster and checked against it, so applying it changes nothing.

```
helm/                        values for each Helm release (only what differs from the chart's defaults)
  cert-manager.yaml            jetstack/cert-manager v1.20.2           ns cert-manager
  cloudnative-pg.yaml          cnpg/cloudnative-pg 0.29.1              ns cnpg-system   (release "cnpg")
  kube-prometheus-stack.yaml   prometheus-community/... 92.16.0        ns monitoring
  grafana.yaml                 grafana/grafana 10.5.15                 ns monitoring    (release "my-grafana")
  loki.yaml                    grafana/loki 7.5.0                      ns monitoring
  tempo.yaml                   grafana/tempo 1.24.4                    ns monitoring
  alloy.yaml                   grafana/alloy 1.14.4                    ns monitoring
  argocd.yaml                  argo/argo-cd 10.11.7 (Argo CD 3.5.7)    ns argocd
manifests/
  data/                        Postgres (CloudNativePG Cluster), RabbitMQ (RabbitmqCluster), Redis (StatefulSet), with their monitors
  monitoring/                  cAdvisor, Grafana's Loki/Tempo datasources, the RabbitMQ dashboard
  argocd/                      the apps Argo CD deploys: the `apps` project and one Application per app
Makefile                     one target per component, plus `make all`
```

The RabbitMQ cluster operator isn't copied here. `make rabbitmq-operator` applies its pinned upstream release manifest (v2.23.2, `cluster-operator-ghcr-io.yml`), which is exactly what's installed.

## What runs where

| Namespace | What | Notes |
| --- | --- | --- |
| `cert-manager` | cert-manager | Webhook certificates for the RabbitMQ operator |
| `cnpg-system` | CloudNativePG operator | Manages the `postgres` cluster |
| `rabbitmq-system` | RabbitMQ cluster operator | Manages the `rabbitmq` cluster |
| `default` | `postgres` (1 instance, Postgres 18), `rabbitmq` (1 replica, 4.3), `redis` (8, with an exporter sidecar) | Services: `postgres-rw`/`-ro`/`-r`, `rabbitmq`, `redis` |
| `monitoring` | Prometheus, Grafana, Loki, Tempo, Alloy, cAdvisor, node-exporter, kube-state-metrics | Grafana and Prometheus pick up dashboards, ServiceMonitors and PodMonitors from every namespace |
| `argocd` | Argo CD | Deploys the apps from Git. UI at `http://192.168.68.57:30081`, user `admin`; `make argocd-password` prints the first password |

Docker Desktop specifics: volumes use the `hostpath` storage class, and cAdvisor runs as its own DaemonSet because the kubelet's built-in one can't see container names on Docker Desktop (see `manifests/monitoring/cadvisor.yaml`).

## Secrets

Secrets are never committed. These must exist before `make data` and `make grafana`. Create them with `kubectl create`, not `kubectl apply`: apply keeps a plain-text copy of the values in the `last-applied-configuration` annotation.

```sh
# Postgres superuser. CloudNativePG reads it (enableSuperuserAccess is on); nothing
# else should log in as it. cnpg.io/reload=true makes a new password take effect.
kubectl -n default create secret generic postgres-superuser --type=kubernetes.io/basic-auth \
  --from-literal=username=postgres --from-literal=password='<superuser password>'
kubectl -n default label secret postgres-superuser cnpg.io/reload=true

# Grafana's read-only database user (the `grafana` role in manifests/data/postgres.yaml),
# and the same password for Grafana's PostgreSQL datasource (helm/grafana.yaml).
kubectl -n default create secret generic grafana-postgres-role --type=kubernetes.io/basic-auth \
  --from-literal=username=grafana --from-literal=password='<grafana password>'
kubectl -n default label secret grafana-postgres-role cnpg.io/reload=true
kubectl -n monitoring create secret generic grafana-postgres --from-literal=password='<grafana password>'

# Redis password (the server and its exporter read it)
kubectl -n default create secret generic redis-secret --from-literal=REDIS_PASSWORD='<redis password>'
```

The operators generate the rest: CloudNativePG creates `postgres-app` (the `app` user the importer uses), and the RabbitMQ operator creates `rabbitmq-default-user`. To rebuild the cluster without losing access to the data, reuse the old values. The data itself is on `hostpath` volumes and isn't backed up.

To rotate a password, replace the Secret, which drops any old annotation, then restart whatever reads it (CloudNativePG picks up its own):

```sh
kubectl -n default create secret generic redis-secret --from-literal=REDIS_PASSWORD='<new>' \
  --dry-run=client -o yaml | kubectl replace -f -
```

## Rebuild from scratch

```sh
make repos
# create the Secrets above, then:
make all
```

`make all` runs in dependency order: cert-manager, then the operators, then Prometheus (whose CRDs the monitors need), the data services, then the rest of monitoring, then Argo CD. That includes the importer's Application. Its Secrets aren't in Git, so create them first from the importer repo (`make secrets`), then sync it in Argo CD.

## Changing something

Edit the file, then run its target, e.g. `make loki` or `make data`. Each target is an idempotent `helm upgrade --install` or `kubectl apply`. To upgrade a chart, change its `--version` in the Makefile and check the chart's upgrade notes first.

`make diff` shows any drift between `manifests/` and the cluster. For a Helm release, compare `helm get values <release> -n <namespace>` with its file.

## Apps (Argo CD)

Each app's manifests live in its own repo; `manifests/argocd/` has one Application per app that points at them. They belong to the `apps` project, which only allows the app's repo as a source and its own namespace as a destination.

| Application | Source | Sync |
| --- | --- | --- |
| `importer` | `c88lopez/importer`, `k8s/` on `main` | manual: press Sync in the UI |

Deleting an Application leaves what it deployed running (there's no resources-finalizer).
