# Everything that runs in the cluster except the apps (they deploy from their
# own repos, e.g. importer). `make all` installs it in dependency order on an
# empty cluster; each target is also safe to re-run on its own to apply a change.
#
# Releases keep the names they were first installed with (cnpg, my-grafana):
# renaming a Helm release means uninstalling and reinstalling it.

.PHONY: all repos cert-manager cloudnative-pg rabbitmq-operator kube-prometheus-stack grafana loki tempo alloy data monitoring-manifests argocd argocd-password argocd-image-updater argocd-apps diff

RABBITMQ_OPERATOR := https://github.com/rabbitmq/cluster-operator/releases/download/v2.23.2/cluster-operator-ghcr-io.yml

all: repos cert-manager cloudnative-pg rabbitmq-operator kube-prometheus-stack data grafana loki tempo alloy monitoring-manifests argocd argocd-image-updater argocd-apps ## install everything, in order (needs the Secrets, see README)

repos: ## add the Helm chart repositories
	helm repo add jetstack https://charts.jetstack.io
	helm repo add cnpg https://cloudnative-pg.github.io/charts
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update

## --- operators ---
cert-manager: ## cert-manager (the RabbitMQ operator's webhook certificates)
	helm upgrade --install cert-manager jetstack/cert-manager --version v1.20.2 \
	  -n cert-manager --create-namespace -f helm/cert-manager.yaml --wait

cloudnative-pg: ## CloudNativePG operator
	helm upgrade --install cnpg cnpg/cloudnative-pg --version 0.29.1 \
	  -n cnpg-system --create-namespace -f helm/cloudnative-pg.yaml --wait

rabbitmq-operator: ## RabbitMQ cluster operator (upstream manifest, pinned)
	kubectl apply -f $(RABBITMQ_OPERATOR)
	kubectl -n rabbitmq-system rollout status deployment/rabbitmq-cluster-operator

## --- data services ---
data: ## Postgres, RabbitMQ and Redis in `default` (needs their Secrets first)
	kubectl apply -f manifests/data/

## --- monitoring ---
kube-prometheus-stack: ## Prometheus, its operator, kube-state-metrics, node-exporter
	helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack --version 92.16.0 \
	  -n monitoring --create-namespace -f helm/kube-prometheus-stack.yaml --wait

grafana: ## Grafana (needs the grafana-postgres Secret)
	helm upgrade --install my-grafana grafana/grafana --version 10.5.15 \
	  -n monitoring -f helm/grafana.yaml --wait

loki: ## Loki, log storage
	helm upgrade --install loki grafana/loki --version 7.5.0 -n monitoring -f helm/loki.yaml --wait

tempo: ## Tempo, trace storage
	helm upgrade --install tempo grafana/tempo --version 1.24.4 -n monitoring -f helm/tempo.yaml --wait

alloy: ## Alloy: ships pod logs to Loki, forwards OTLP traces to Tempo
	helm upgrade --install alloy grafana/alloy --version 1.14.4 -n monitoring -f helm/alloy.yaml --wait

monitoring-manifests: ## cAdvisor, Grafana's Loki/Tempo datasources, the RabbitMQ dashboard
	kubectl apply -f manifests/monitoring/

## --- delivery ---
argocd: ## Argo CD, which deploys the apps from Git (UI: http://<node>:30081)
	helm upgrade --install argocd argo/argo-cd --version 10.11.7 \
	  -n argocd --create-namespace -f helm/argocd.yaml --wait

argocd-password: ## print the initial admin password (delete the Secret once you have changed it)
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo

argocd-image-updater: ## Image Updater: commits new image tags to the apps' repos (needs the importer-git-write Secret)
	helm upgrade --install argocd-image-updater argo/argocd-image-updater --version 1.4.0 \
	  -n argocd -f helm/argocd-image-updater.yaml --wait

argocd-apps: ## the apps Argo CD deploys (manifests/argocd/): their project and Applications
	kubectl apply -f manifests/argocd/

## --- checks ---
diff: ## show how the cluster differs from manifests/ (Helm releases: compare with helm get values)
	@kubectl diff -f manifests/data/ -f manifests/monitoring/ -f manifests/argocd/ && echo "manifests/: no differences"
