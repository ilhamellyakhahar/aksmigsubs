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

# Validate required variables
REQUIRED_VARS=(VNET LOCATION RG CIDR SUBNET AKS SYSTEM_SIZE USER_SIZE SOURCE_CONTEXT DNS_RG DNS_ZONE KUBE_CONFIG_PATH)
for var in "${REQUIRED_VARS[@]}"; do
  if [ -z "${!var:-}" ]; then
    error_exit "Environment variable $var is not set. Please check your .env file."
  fi
done
echo "All required environment variables are set."

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

# Install ArgoCD on the new AKS cluster
echo "Installing ArgoCD..."
echo "Applying ArgoCD CRDs..."
kubectl apply -k "https://github.com/argoproj/argo-cd/manifests/crds?ref=v3.2.2" --context="$AKS" || error_exit "Failed to apply ArgoCD CRDs."
echo "ArgoCD CRDs applied."
cat > helm/argocd/terraform.tfvars << EOL
kubeconfig_path = "$KUBE_CONFIG_PATH"
kubeconfig_context = "$AKS"
EOL
cd helm/argocd
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

echo "Importing ArgoCD configurations to $AKS"
kubectl apply -f argoconfigs/projects.yaml --context=$AKS
kubectl apply -f argoconfigs/applications.yaml --context=$AKS
kubectl apply -f argoconfigs/applicationsets.yaml --context=$AKS
kubectl apply -f argoconfigs/repositories.yaml --context=$AKS
echo "Import completed successfully."

# Update DNS A records to point to the new AKS ingress IP
echo "Updating DNS A records to point to the new AKS ingress IP..."
old_ip=$(kubectl get svc ingress-nginx-controller -n ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' --context=$SOURCE_CONTEXT)
new_ip=$(kubectl get svc ingress-nginx-controller -n ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' --context=$AKS)

echo "Searching for A records with IP $old_ip ..."
records=$(az network dns record-set a list -g "$DNS_RG" -z "$DNS_ZONE" --query "[?ARecords[?ipv4Address=='$old_ip']].name" -o tsv)
if [ -z "$records" ]; then
  echo "No A records found with IP $old_ip. Exiting."
  exit 0
fi
echo "Found records: $records"
echo "Updating A records from $old_ip to $new_ip ..."
for name in $records; do
  echo "Updating record: $name"
  az network dns record-set a remove-record -g "$DNS_RG" -z "$DNS_ZONE" -n "$name" -a "$old_ip"
  az network dns record-set a add-record -g "$DNS_RG" -z "$DNS_ZONE" -n "$name" -a "$new_ip"
done
echo "DNS A records updated."