# platform

Everything that runs in the Docker Desktop cluster (`192.168.68.57`, context `docker-desktop`) except the applications: operators, data services, monitoring and Argo CD. The apps' manifests live in their own repos, like [importer](https://github.com/c88lopez/importer).

Argo CD deploys all of it from this repo's `main`: one Application per file in `apps/`, under a root Application (`bootstrap/platform.yaml`). A commit is a deploy. The Makefile only bootstraps Argo CD itself on an empty cluster.

```
bootstrap/platform.yaml      the `platform` AppProject and the root Application, applied once by `make bootstrap`
apps/                        one Argo CD Application per component: chart, version, release name, namespace, sync wave
helm/                        values for each Helm release (only what differs from the chart's defaults)
  cert-manager.yaml            jetstack/cert-manager v1.20.2           ns cert-manager
  cloudnative-pg.yaml          cnpg/cloudnative-pg 0.29.1              ns cnpg-system   (release "cnpg")
  metrics-server.yaml          metrics-server/metrics-server 3.14.0    ns kube-system
  keda.yaml                    kedacore/keda 2.21.0                    ns keda
  kube-prometheus-stack.yaml   prometheus-community/... 92.16.0        ns monitoring
  grafana.yaml                 grafana/grafana 10.5.15                 ns monitoring    (release "my-grafana")
  loki.yaml                    grafana/loki 7.5.0                      ns monitoring
  tempo.yaml                   grafana/tempo 1.24.4                    ns monitoring
  alloy.yaml                   grafana/alloy 1.14.4                    ns monitoring
  argocd.yaml                  argo/argo-cd 10.11.7 (Argo CD 3.5.7)    ns argocd
  argocd-image-updater.yaml    argo/argocd-image-updater 1.4.0         ns argocd
manifests/
  data/                        Postgres (CloudNativePG Cluster), RabbitMQ (RabbitmqCluster), Redis (StatefulSet), with their monitors
  monitoring/                  cAdvisor, Grafana's Loki/Tempo datasources, the RabbitMQ dashboard
  argocd/                      the apps Argo CD deploys: the `apps` project and one Application per app, and what Image Updater watches
  rabbitmq-operator/           a kustomization of the operator's pinned upstream release manifest (v2.23.2, `cluster-operator-ghcr-io.yml`)
Makefile                     `make bootstrap`: installs Argo CD, then the root Application
```

## What runs where

| Namespace | What | Notes |
| --- | --- | --- |
| `cert-manager` | cert-manager | Webhook certificates for the RabbitMQ operator |
| `cnpg-system` | CloudNativePG operator | Manages the `postgres` cluster |
| `rabbitmq-system` | RabbitMQ cluster operator | Manages the `rabbitmq` cluster |
| `kube-system` | metrics-server | Pods' current CPU and memory, for HorizontalPodAutoscalers and `kubectl top` |
| `keda` | KEDA | Scales Deployments on events; importer-worker on its queue's length |
| `data` | `postgres` (1 instance, Postgres 18), `rabbitmq` (1 replica, 4.3), `redis` (8, with an exporter sidecar) | Services: `postgres-rw`/`-ro`/`-r`, `rabbitmq`, `redis` |
| `monitoring` | Prometheus, Grafana, Loki, Tempo, Alloy, cAdvisor, node-exporter, kube-state-metrics | Grafana and Prometheus pick up dashboards, ServiceMonitors and PodMonitors from every namespace |
| `argocd` | Argo CD, Image Updater | Deploys this repo and the apps from Git, and commits the apps' new image tags. UI at `http://192.168.68.57:30081`, user `admin`; `make argocd-password` prints the first password |

Docker Desktop specifics: volumes use the `hostpath` storage class, and cAdvisor runs as its own DaemonSet because the kubelet's built-in one can't see container names on Docker Desktop (see `manifests/monitoring/cadvisor.yaml`).

## Secrets

Secrets are never committed. Create these before `make bootstrap`: the `data`, `grafana` and `argocd-image-updater` Applications need them. Create them with `kubectl create`, not `kubectl apply`: apply keeps a plain-text copy of the values in the `last-applied-configuration` annotation.

```sh
# Postgres superuser. CloudNativePG reads it (enableSuperuserAccess is on); nothing
# else should log in as it. cnpg.io/reload=true makes a new password take effect.
kubectl -n data create secret generic postgres-superuser --type=kubernetes.io/basic-auth \
  --from-literal=username=postgres --from-literal=password='<superuser password>'
kubectl -n data label secret postgres-superuser cnpg.io/reload=true

# Grafana's read-only database user (the `grafana` role in manifests/data/postgres.yaml),
# and the same password for Grafana's PostgreSQL datasource (helm/grafana.yaml).
kubectl -n data create secret generic grafana-postgres-role --type=kubernetes.io/basic-auth \
  --from-literal=username=grafana --from-literal=password='<grafana password>'
kubectl -n data label secret grafana-postgres-role cnpg.io/reload=true
kubectl -n monitoring create secret generic grafana-postgres --from-literal=password='<grafana password>'

# Grafana's admin login (helm/grafana.yaml, admin.existingSecret)
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=admin-user=admin --from-literal=admin-password='<admin password>'

# Redis password (the server and its exporter read it)
kubectl -n data create secret generic redis-secret --from-literal=REDIS_PASSWORD='<redis password>'

# Image Updater's deploy key: write access to the importer repo, nothing else.
# The private key goes only into the Secret.
ssh-keygen -t ed25519 -N '' -C argocd-image-updater -f importer-deploy-key
gh repo deploy-key add importer-deploy-key.pub -R c88lopez/importer --allow-write -t argocd-image-updater
kubectl -n argocd create secret generic importer-git-write --from-file=sshPrivateKey=importer-deploy-key
rm importer-deploy-key importer-deploy-key.pub
```

The operators generate the rest: CloudNativePG creates `postgres-app` (the `app` user the importer uses), and the RabbitMQ operator creates `rabbitmq-default-user`. To rebuild the cluster without losing access to the data, reuse the old values. The data itself is on `hostpath` volumes and isn't backed up.

To rotate a password, replace the Secret, which drops any old annotation, then restart whatever reads it (CloudNativePG picks up its own):

```sh
kubectl -n data create secret generic redis-secret --from-literal=REDIS_PASSWORD='<new>' \
  --dry-run=client -o yaml | kubectl replace -f -
```

## Rebuild from scratch

```sh
# create the Secrets above, then:
make bootstrap
```

`make bootstrap` installs Argo CD from `helm/argocd.yaml` and applies the root Application. Argo CD then syncs `apps/` in waves, each waiting for the previous one to be Healthy: cert-manager, then Prometheus (whose CRDs the monitors need, the CloudNativePG chart's PodMonitor included), then the operators, the data services, the rest of monitoring, and last Argo CD itself, Image Updater and the importer's Application. The importer's Secrets aren't in Git: once `postgres-app` and `rabbitmq-default-user` exist, create them from the importer repo (`make secrets`), then sync it in Argo CD.

## Changing something

Edit the file and merge it to `main`; Argo CD syncs it within about 3 minutes. To upgrade a chart, change `targetRevision` in its `apps/<name>.yaml` and check the chart's upgrade notes first. For Argo CD, also change `ARGOCD_CHART` in the Makefile.

Every Application syncs automatically with prune and without selfHeal, like the importer: a change made by hand stays until the next commit and shows as OutOfSync meanwhile. The Argo CD UI shows any drift and its diff. Postgres, RabbitMQ and Redis are never pruned or deleted by Argo CD (`Prune=false,Delete=false`); removing them takes a `kubectl delete`.

To add a component, add its Application to `apps/` with a sync wave, and its namespace to the `platform` project's destinations in `bootstrap/platform.yaml` (then `make root`).

## Apps (Argo CD)

Each app's manifests live in its own repo; `manifests/argocd/` has one Application per app that points at them. They belong to the `apps` project, which only allows the app's repo as a source and its own namespace as a destination.

| Application | Source | Sync |
| --- | --- | --- |
| `importer` | `c88lopez/importer`, `k8s/` on `main` | automatic, with prune; no selfHeal |

Image Updater deploys new releases. Every 2 minutes it checks the registry for each image in `manifests/argocd/*-image-updater.yaml`. When it finds a newer `x.y.z` tag in the allowed range, it commits it to the app's kustomization on `main` with the app's deploy key, and Argo CD syncs that commit. For importer, `make release VERSION=1.7.0` is the whole release. To pause it, `kubectl -n argocd scale deployment/argocd-image-updater-controller --replicas=0`. To roll back, add the bad version to the rule's `ignoreTags` (`commonUpdateSettings.ignoreTags: ["1.7.0"]`) and merge it, then revert its commit in the app's repo. Reverting alone doesn't stick: on its next check Image Updater sees the bad tag is still the newest and commits it again.

Deleting an Application leaves what it deployed running (there's no resources-finalizer).
