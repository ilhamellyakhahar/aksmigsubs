#!/bin/bash

set -euo pipefail

echo "Please provide the following details for AKS migration:"
read -p "Enter VNet name: " vnet
read -p "Enter Location [eastus]: " location
read -p "Enter Resource Group name: " rg
read -p "Enter CIDR block [10.0.0.0/16]: " cidr_input
read -p "Enter Subnet block [10.0.1.0/24]: " subnet_input
read -p "Enter AKS cluster name: " aks
read -p "Enter System Node Size [Standard_DS2_v2]: " system_size
read -p "Enter User Node Size [Standard_DS2_v2]: " user_size

cat > terraform/terraform.tfvars << EOL
vnet        = "$vnet"
location    = "$location"
rg          = "$rg"
cidr        = ["$cidr_input"]
subnet      = ["$subnet_input"]
aks         = "$aks"
system_size = "$system_size"
user_size   = "$user_size"
EOL

echo "Deploying Infrastructure..."
cd terraform
terraform init
terraform apply -auto-approve || error_exit "Terraform Infrastructure apply failed"
echo "Infrastructure deployed successfully."

echo "Fetching AKS credentials..."
az aks get-credentials --resource-group "$rg" --name "$aks" --overwrite-existing
echo "Credentials fetched."

echo "Applying ArgoCD CRDs..."
kubectl apply -k "https://github.com/argoproj/argo-cd/manifests/crds?ref=v3.2.2"
echo "ArgoCD CRDs applied."

read -p "Enter current cluster context " kube_context
read -p "Enter kube config path " kube_config_path

cat > helm/argocd/terraform.tfvars << EOL
kubeconfig_path = "$kube_config_path"
kubeconfig_context = "$kube_context"
EOL

cd helm/argocd
echo "Deploying ArgoCD..."
terraform init
terraform apply -auto-approve || error_exit "Terraform Infrastructure apply failed"
echo "ArgoCD deployed successfully."

read -p "Enter the source cluster context: " source_context

echo "Exporting ArgoCD configurations from $source_context"

cd ../../..

mkdir argoconfigs
kubectl get appprojects -n argocd -o yaml --context=$source_context > argoconfigs/projects.yaml
kubectl get applications -n argocd -o yaml --context=$source_context > argoconfigs/applications.yaml
kubectl get applicationsets -n argocd -o yaml --context=$source_context > argoconfigs/applicationsets.yaml
kubectl get secrets -n argocd -l argocd.argoproj.io/secret-type=repository -o yaml --context=$source_context > argoconfigs/repositories.yaml
echo "Export completed successfully."

echo "Importing ArgoCD configurations to $kube_context"
kubectl apply -f argoconfigs/projects.yaml --context=$kube_context
kubectl apply -f argoconfigs/applications.yaml --context=$kube_context
kubectl apply -f argoconfigs/applicationsets.yaml --context=$kube_context
kubectl apply -f argoconfigs/repositories.yaml --context=$kube_context
echo "Import completed successfully."

old_ip=$(kubectl get svc ingress-nginx-controller -n ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' --context=$source_context)
new_ip=$(kubectl get svc ingress-nginx-controller -n ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}' --context=$kube_context)

echo "Starting DNS A record update process..."
echo "Please provide the following details:"
read -p "Enter Resource Group name: " dns_rg
read -p "Enter DNS Zone name: " zone

echo "Searching for A records with IP $old_ip ..."

records=$(az network dns record-set a list -g "$dns_rg" -z "$zone" --query "[?ARecords[?ipv4Address=='$old_ip']].name" -o tsv)
if [ -z "$records" ]; then
  echo "No A records found with IP $old_ip. Exiting."
  exit 0
fi

for name in $records; do
  echo "Updating record: $name"
  az network dns record-set a remove-record -g "$dns_rg" -z "$zone" -n "$name" -a "$old_ip"
  az network dns record-set a add-record -g "$dns_rg" -z "$zone" -n "$name" -a "$new_ip"
done

echo "DNS update completed successfully."