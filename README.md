# AKS with Azure Files NFS and Encryption in Transit

This project deploys an Azure Kubernetes Service (AKS) cluster with Azure Files NFS v4.1 storage and **encryption in transit** enabled for secure data transfer.

## Architecture

- **AKS Cluster**: Kubernetes 1.33 with Azure CNI networking
- **Storage**: Azure Files Premium with NFS v4.1 protocol
- **Network**: Private endpoint with custom DNS resolution
- **Security**: Encryption in transit using TLS via Azure File CSI driver v1.33.5+

## Prerequisites

- Azure CLI (`az`) installed and authenticated
- Terraform >= 1.0
- kubectl installed
- Azure subscription with appropriate permissions

## Infrastructure Components

1. **Resource Group**: Contains all resources
2. **Virtual Network**: 10.20.0.0/16 CIDR with subnet 10.20.1.0/24
3. **Storage Account**: Premium FileStorage with NFS support
4. **Private Endpoint**: Secure access to storage account (10.20.1.4)
5. **Private DNS Zone**: `privatelink.file.core.windows.net` for name resolution
6. **AKS Cluster**: Single-node cluster (can be scaled)
7. **NFS Share**: 1TB NFS v4.1 file share

## Quick Start

### 1. Configure Variables

Create a `terraform.tfvars` file:

```hcl
location       = "eastasia"
rg_name        = "oc-rg-eastasia"
vnet_name      = "oc-vnet"
subnet_name    = "oc-subnet"
aks_name       = "oc-aks"
storage_name   = "ocmsgsgenaipmodelweights"
share_name     = "ocmsgsgenaipmodelweights"
```

### 2. Set Azure Subscription

```bash
export ARM_SUBSCRIPTION_ID=$(az account show --query 'id' -o tsv)
```

### 3. Deploy Infrastructure

```bash
terraform init
terraform plan -var-file=terraform.tfvars
terraform apply -var-file=terraform.tfvars
```

### 4. Create NFS Share

Due to Azure policy restrictions on shared key access, the NFS share must be created via Azure CLI:

```bash
az storage share-rm create \
  --resource-group oc-rg-eastasia \
  --storage-account ocmsgsgenaipmodelweights \
  --name ocmsgsgenaipmodelweights \
  --enabled-protocols NFS \
  --quota 1024
```

### 5. Configure kubectl

```bash
az aks get-credentials --resource-group oc-rg-eastasia --name oc-aks
```

### 6. Deploy PersistentVolume

```bash
kubectl apply -f nfs-pv-csi-encrypted.yaml
```

### 7. Test with Sample Pod

```bash
kubectl apply -f test-pod.yaml
kubectl exec nfs-test-pod -- sh -c "echo 'test data' > /data/test.txt && cat /data/test.txt"
```

## Encryption in Transit

### How It Works

The Azure File CSI driver v1.33.5+ includes built-in support for encryption in transit when `encryptInTransit: "true"` is set in the PersistentVolume configuration.

The CSI driver uses an **azurefile-proxy** component (based on stunnel) that:
1. Intercepts NFS v4.1 traffic
2. Wraps it in TLS 1.3 encryption
3. Forwards encrypted traffic to Azure Files over the private endpoint

### Configuration

In `nfs-pv-csi-encrypted.yaml`:

```yaml
spec:
  csi:
    driver: file.csi.azure.com
    volumeAttributes:
      protocol: nfs
      encryptInTransit: "true"  # Enables encryption
      server: 10.20.1.4          # Private endpoint IP
```

### Verification

**1. Check CSI Driver Version:**
```bash
kubectl get pods -n kube-system -l app=csi-azurefile-node \
  -o jsonpath='{.items[0].spec.containers[?(@.name=="azurefile")].image}'
```
Expected: `v1.33.5` or higher

**2. Verify Encryption in Logs:**
```bash
kubectl logs -n kube-system <csi-azurefile-node-pod> -c azurefile | grep "encryptInTransit"
```
Expected output:
```
encryptInTransit is enabled, mount by azurefile-proxy
```

**3. Check Pod Mount:**
```bash
kubectl exec <pod-name> -- mount | grep /data
```
Should show NFS v4.1 mount via private endpoint IP

## Files

- `main.tf` - Terraform infrastructure definition
- `terraform.tfvars` - Configuration variables (not committed)
- `nfs-pv-csi-encrypted.yaml` - PersistentVolume with encryption enabled
- `test-pod.yaml` - Sample pod for testing NFS mount

## Important Notes

### Shared Key Access Restriction

The storage account has `shared_access_key_enabled = false` due to Azure policy. This means:
- NFS share must be managed via Azure CLI (not Terraform)
- Azure RBAC is used for authentication instead of storage keys

### AKS Version Requirements

- **Minimum AKS version**: 1.33
- **Minimum CSI driver**: v1.33.0
- Encryption in transit is a **Preview** feature

### Platform Limitations

- ARM64 nodes are not currently supported
- Azure Linux is not currently supported

## Troubleshooting

### Pod Stuck in ContainerCreating

```bash
kubectl describe pod <pod-name>
```

Common issues:
1. **DNS resolution failed**: Verify Private DNS A record exists
2. **Mount failed**: Check if NFS share exists
3. **Permission denied**: Verify network rules allow subnet access

### Encryption Not Enabled

If logs don't show "encryptInTransit is enabled":
1. Verify AKS cluster is version 1.33+
2. Check CSI driver version is v1.33.5+
3. Confirm `encryptInTransit: "true"` in PV spec
4. Recreate the pod to trigger new mount

### Storage Account Access Issues

If facing 403 errors:
- Check storage account network rules include the AKS subnet
- Verify private endpoint is properly connected
- Ensure service endpoint `Microsoft.Storage` is enabled on subnet

## Security Best Practices

1. **Private Networking**: All traffic stays within Azure backbone via private endpoint
2. **Network Policies**: Storage account denies public access by default
3. **Encryption**: Data encrypted in transit using TLS 1.3
4. **RBAC**: Use Azure RBAC instead of shared keys when possible

## Cleanup

```bash
# Delete Kubernetes resources
kubectl delete -f test-pod.yaml
kubectl delete -f nfs-pv-csi-encrypted.yaml

# Delete NFS share
az storage share-rm delete \
  --resource-group oc-rg-eastasia \
  --storage-account ocmsgsgenaipmodelweights \
  --name ocmsgsgenaipmodelweights

# Destroy Terraform infrastructure
terraform destroy -var-file=terraform.tfvars
```

## References

- [Azure File CSI Driver - NFS Encryption in Transit](https://github.com/kubernetes-sigs/azurefile-csi-driver/tree/master/deploy/example/nfs)
- [Azure Files NFS v4.1 Documentation](https://learn.microsoft.com/en-us/azure/storage/files/files-nfs-protocol)
- [AKS Private Clusters](https://learn.microsoft.com/en-us/azure/aks/private-clusters)

## License

This project is for demonstration purposes.
