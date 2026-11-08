# Everything that runs in the cluster except the apps (they deploy from their
# own repos, e.g. importer) is deployed by Argo CD from this repo: one
# Application per file in apps/. A commit to main is a deploy.
#
# The Makefile only bootstraps that: it installs Argo CD and applies the root
# Application, which then installs everything else, in order. It's also safe
# to re-run on a running cluster (it's how a change to Argo CD's own settings
# reaches it if Argo CD can't sync itself).

.PHONY: bootstrap repos argocd root argocd-password

# Keep equal to targetRevision in apps/argocd.yaml.
ARGOCD_CHART := 10.11.7

bootstrap: repos argocd root ## install Argo CD, then the root Application (needs the Secrets, see README)

repos: ## add the Argo CD Helm chart repository (the others are only read by Argo CD)
	helm repo add argo https://argoproj.github.io/argo-helm
	helm repo update argo

# Rendered and applied rather than `helm install`ed: Argo CD then owns its own
# resources, with no Helm release next to it claiming them too.
argocd: ## Argo CD, from helm/argocd.yaml (UI: http://<node>:30081)
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	helm template argocd argo/argo-cd --version $(ARGOCD_CHART) -n argocd -f helm/argocd.yaml --include-crds \
	  | kubectl apply -n argocd --server-side --force-conflicts -f -
	kubectl -n argocd rollout status deployment/argocd-server
	kubectl -n argocd rollout status deployment/argocd-repo-server
	kubectl -n argocd rollout status statefulset/argocd-application-controller

root: ## the `platform` project and the root Application (bootstrap/platform.yaml)
	kubectl apply -f bootstrap/platform.yaml

argocd-password: ## print the initial admin password (delete the Secret once you have changed it)
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
