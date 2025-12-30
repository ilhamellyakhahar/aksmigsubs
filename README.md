# AKS Migration

This project automates migrating workloads from a source AKS cluster to a new AKS cluster by:
- Provisioning AKS and networking via Terraform
- Installing NGINX Ingress and Cert-Manager
- Installing ArgoCD and migrating ArgoCD projects, applications, applicationsets, and repository secrets
- Fetching unmanaged objects and apply it
- Updating public DNS A records to the new ingress IP

## Prerequisites
- Azure subscription access with enough permissions
- Tools installed in your shell environment:
	- Azure CLI
	- Terraform
	- kubectl
	- helm
	- jq
- Existing source AKS kube context available locally and running

## Usage
Run in WSL or a Linux shell for best compatibility.

```bash
# 1) Log in to Azure
az login
az account set --subscription "<subscription>"

# 2) Verify tools
az version
terraform version
kubectl version --client

# 3) Prepare .env in the repo root (see example above)

# 4) Run the migration
./migration.sh
```