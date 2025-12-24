login to azure cli
terraform installed
prepare the value (it get from existing aks metadata)
- vnet name
- location
- rg
- vnet cidr
- subnet cidr
- aks name
- system node size
- user node size
- kube config path  
- kube context
    - exist context
    - new context

run migration.sh

the automation will create
- vnet
- aks
- argocd
- copy argocd existing config
- apply argocd to new cluster