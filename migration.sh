#!/bin/bash
set -euo pipefail

# error handling function
error_exit() {
  echo "$1" 1>&2
  exit 1
}

# load variables from .env file
if [ -f .env ]; then
  set -a
  source .env
  set +a
else
  error_exit ".env file not found."
fi

# Generate Terraform variable files
echo "Generating Terraform variable files..."
cat > terraform/terraform.tfvars << EOL
vnet        = "$VNET"
location    = "$LOCATION"
rg          = "$RG"
cidr        = ["$CIDR"]
subnet      = ["$SUBNET"]
aks         = "$AKS"
system_size = "$SYSTEM_SIZE"
user_size   = "$USER_SIZE"
EOL
echo "Terraform variable files generated."

# Deploy infrastructure using Terraform
echo "Deploying Infrastructure..."
cd terraform
terraform init || error_exit "Terraform Initialization failed"
terraform apply -auto-approve || error_exit "Terraform Infrastructure apply failed"
echo "Infrastructure deployed successfully."

# Fetch AKS credentials
echo "Fetching AKS credentials..."
az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing || error_exit "Failed to fetch AKS credentials, please check your Azure CLI login and permissions."
echo "Credentials fetched."

# Install Nginx Ingress Controller on the new AKS cluster
echo "Installing Nginx Ingress Controller..."
cat > helm/nginx/terraform.tfvars << EOL
kubeconfig_path = "$KUBE_CONFIG_PATH"
kubeconfig_context = "$AKS"
EOL
cd helm/nginx
echo "Deploying Nginx Ingress Controller..."
terraform init || error_exit "Terraform Initialization failed"
terraform apply -auto-approve || error_exit "Terraform apply failed"
echo "Nginx Ingress Controller deployed successfully."

# Install Cert-Manager on the new AKS cluster
echo "Installing Cert-Manager..."
echo "Applying Cert-Manager CRDs..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.19.2/cert-manager.crds.yaml --context="$AKS" || error_exit "Failed to apply Cert-Manager CRDs."
echo "Cert-Manager CRDs applied."
cat > ../cert-manager/terraform.tfvars << EOL
kubeconfig_path = "$KUBE_CONFIG_PATH"
kubeconfig_context = "$AKS"
EOL
cd ../cert-manager
echo "Deploying Cert-Manager..."
terraform init || error_exit "Terraform Initialization failed"
terraform apply -auto-approve || error_exit "Terraform apply failed"
kubectl apply -f issuer.yml --context="$AKS" || error_exit "Failed to apply Issuer."
echo "Cert-Manager deployed successfully."

# Install ArgoCD on the new AKS cluster
echo "Installing ArgoCD..."
echo "Applying ArgoCD CRDs..."
kubectl apply -k "https://github.com/argoproj/argo-cd/manifests/crds?ref=v3.2.2" --context="$AKS" || error_exit "Failed to apply ArgoCD CRDs."
echo "ArgoCD CRDs applied."
cat > ../argocd/terraform.tfvars << EOL
kubeconfig_path = "$KUBE_CONFIG_PATH"
kubeconfig_context = "$AKS"
EOL
cd ../argocd
# sed -i "s|domain: .*|domain: ${ARGO_DOMAIN}|" values.yml
echo "Deploying ArgoCD..."
terraform init || error_exit "Terraform Initialization failed"
terraform apply -auto-approve || error_exit "Terraform apply failed"
echo "ArgoCD deployed successfully."

# Migrate ArgoCD configurations from source to new AKS cluster
echo "Exporting ArgoCD configurations from $SOURCE_CONTEXT"
cd ../../..
mkdir argoconfigs
kubectl get appprojects -n argocd -o yaml --context=$SOURCE_CONTEXT > argoconfigs/projects.yaml
kubectl get applications -n argocd -o yaml --context=$SOURCE_CONTEXT > argoconfigs/applications.yaml
kubectl get applicationsets -n argocd -o yaml --context=$SOURCE_CONTEXT > argoconfigs/applicationsets.yaml
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=repository -o yaml --context=$SOURCE_CONTEXT > argoconfigs/repositories.yaml
echo "Export completed successfully."

sed -i '/uid:/d;/resourceVersion:/d;/creationTimestamp:/d;/managedFields:/,/^  [^ ]/d' \
  argoconfigs/repositories.yaml

kubectl --context=$SOURCE_CONTEXT get ns -o name \
  | awk -F/ '!/^(namespace\/kube-|namespace\/default)/ {print $2}' \
  | while read ns; do
      kubectl --context=$AKS get ns "$ns" >/dev/null 2>&1 || kubectl --context=$AKS create ns "$ns"
    done

echo "Importing ArgoCD configurations to $AKS"
kubectl apply -f argoconfigs/projects.yaml --context=$AKS || true
kubectl apply -f argoconfigs/applications.yaml  --context=$AKS || true
kubectl apply -f argoconfigs/applicationsets.yaml --context=$AKS || true
kubectl apply -f argoconfigs/repositories.yaml --context=$AKS || true
echo "Import completed successfully."

echo "Get unmanaged objects"
kubectl get deployments,svc,ingress,configmap,secret -A -o json | jq -r '
  .items[] | select(
    (.metadata.namespace | IN("argocd", "cert-manager", "default", "ingress", "kube-node-lease", "kube-public", "kube-system") | not) and
    (.metadata.labels["app.kubernetes.io/instance"] == null) and
    (.metadata.annotations["argocd.argoproj.io/tracking-id"] == null) and
    (.metadata.name != "kube-root-ca.crt") and
    (.type != "helm.sh/release.v1")
  ) | [.metadata.namespace, .kind, .metadata.name] | @tsv' | \
while read -r ns kind name; do
  echo "---" >> unmanaged.yml
  kubectl apply view-last-applied "$kind/$name" -n "$ns" >> unmanaged.yml
done
echo "Unmanaged objects fetched."
echo "Applying unmanaged objects to $AKS"
kubectl apply -f unmanaged.yml --context=$AKS || true
echo "Unmanaged objects applied successfully."

# Update DNS A records to point to the new AKS ingress IP
echo "Switching Azure subscription to $DNS_SUBS ..."
az account set --subscription "$DNS_SUBS" || error_exit "Failed to switch Azure subscription."
echo "Subscription switched."

echo "Updating DNS A records to point to the new AKS ingress IP..."
OLD_IP=$(kubectl get svc nginx-ingress-nginx-controller -n ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' --context=$SOURCE_CONTEXT)
NEW_IP=$(kubectl get svc nginx-ingress-nginx-controller -n ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' --context=$AKS)

echo "Searching for A records with IP $OLD_IP ..."
RECORDS=$(az network dns record-set a list -g "$DNS_RG" -z "$DNS_ZONE" --query "[?ARecords[?ipv4Address=='$OLD_IP']].name" -o tsv)
if [ -z "$RECORDS" ]; then
  echo "No A records found with IP $OLD_IP. Exiting."
  exit 0
fi
echo "Found records: $RECORDS"
echo "Updating A records from $OLD_IP to $NEW_IP ..."
for NAME in $RECORDS; do
  echo "Updating record: $NAME"
  az network dns record-set a remove-record -g "$DNS_RG" -z "$DNS_ZONE" -n "$NAME" -a "$OLD_IP"
  az network dns record-set a add-record -g "$DNS_RG" -z "$DNS_ZONE" -n "$NAME" -a "$NEW_IP"
done
echo "DNS A records updated."