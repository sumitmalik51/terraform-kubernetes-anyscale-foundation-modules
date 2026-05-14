---
name: deploy-azure-aks
description: Guide for deploying the Anyscale Azure AKS new cluster example from examples/azure/aks-new_cluster/. Use when the user asks about deploying, setting up, or configuring Azure AKS for Anyscale.
argument-hint: [step]
allowed-tools: Read, Bash, Grep, Glob
---

# Deploy Azure AKS for Anyscale

Walk the user through deploying the Azure AKS example at `examples/azure/aks-new_cluster/`.

If `$ARGUMENTS` specifies a step (e.g., "terraform", "envoy", "gpu", "register", "operator"), skip to that step. Otherwise, guide from the beginning.

## Prerequisites

Ensure the user has:
- [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/) (signed in via `az login`)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/docs/intro/install/)
- [Anyscale CLI](https://docs.anyscale.com/reference/quickstart-cli/) (>= v0.26.24)
- Terraform >= 1.0.0

## Step 1: Configure Terraform Variables

The user needs a `terraform.tfvars` file in `examples/azure/aks-new_cluster/`. Required variables:

```hcl
azure_tenant_id       = ""  # az account show --query tenantId -o tsv
azure_subscription_id = ""  # az account show --query id -o tsv
azure_location        = ""  # e.g. "Central US"
aks_cluster_name      = ""  # e.g. "my-anyscale-cluster"
```

Key optional variables:
- `gpu_pool_configs` - Map of GPU pool configs. Keys like "T4", "A100". Each needs `name` (max 8 lowercase alphanum chars), `vm_size`, `product_name`, `gpu_count`. Set to `{}` for CPU-only.
- `enable_nfs` - Enable NFS storage (default: false)
- `enable_blob_driver` - Enable Azure Blob CSI driver (default: false)
- `system_vm_size` - System node VM size (default: "Standard_D2s_v5")
- `cpu_vm_size` - CPU node VM size (default: "Standard_D16s_v5")

Read `examples/azure/aks-new_cluster/variables.tf` for the full list.

## Step 2: Apply Terraform

Run from `examples/azure/aks-new_cluster/`:

```shell
terraform init
terraform plan
terraform apply
```

Save the outputs - they contain commands for the remaining steps. Key outputs:
- `aks_get_credentials_command` - Command to authenticate kubectl
- `anyscale_registration_command` - Command to register the Anyscale cloud
- `helm_upgrade_command` - Command to install the Anyscale operator

## Step 3: Get AKS Credentials

Use the terraform output command:

```shell
# From terraform output: aks_get_credentials_command
az aks get-credentials --resource-group <rg-name> --name <cluster-name> --overwrite-existing
```

## Step 4: Install Envoy Gateway

The Anyscale Operator on AKS uses Envoy Gateway (Gateway API) instead of an ingress controller. Requires Kubernetes 1.30+.

Install the Envoy Gateway Helm chart:

```shell
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.0 \
  --namespace envoy-gateway-system \
  --create-namespace

kubectl wait --for=condition=available deployment/envoy-gateway \
  -n envoy-gateway-system --timeout=120s
```

The Gateway/EnvoyProxy/GatewayClass manifests are in `examples/azure/aks-new_cluster/sample-envoy-gateway.yaml`. They reference a TLS Secret name that embeds the Anyscale cloud deployment ID, so apply them after Step 6 (cloud register).

## Step 5 (Optional): Install Nvidia Device Plugin

Only needed if using GPU node pools. The sample values file is at `examples/azure/aks-new_cluster/sample-values_nvdp.yaml`.

```shell
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm upgrade nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --version 0.17.1 \
  --values sample-values_nvdp.yaml \
  --create-namespace \
  --install
```

## Step 6: Register the Anyscale Cloud

Ensure `anyscale login` is done, then use the registration command from terraform output:

```shell
anyscale cloud register \
  --name <anyscale_cloud_name> \
  --region <region> \
  --provider azure \
  --compute-stack k8s \
  --azure-tenant-id <tenant-id> \
  --anyscale-operator-iam-identity <principal-id> \
  --cloud-storage-bucket-name 'abfss://<container>@<storage-account>.dfs.core.windows.net' \
  --cloud-storage-bucket-endpoint 'https://<storage-account>.blob.core.windows.net'
```

Note the returned cloud deployment ID (e.g. `cldrsrc_...`) — needed in the next two steps.

## Step 7: Apply Envoy Gateway Resources

Create the operator namespace if it doesn't already exist:

```shell
kubectl create namespace anyscale-operator
```

In `examples/azure/aks-new_cluster/sample-envoy-gateway.yaml`, replace every occurrence of `<cldrsrc-id>` with the **dash-form** of the cloud deployment ID from Step 6. Kubernetes Secret names can't contain underscores, so the operator stores the cert Secret as `anyscale-cldrsrc-<dash-form>-certificate` — if the register command returned `cldrsrc_abc123xyz`, substitute `cldrsrc-abc123xyz`.

One-liner that does the substitution + apply in one shot:

```shell
CLOUD_ID=cldrsrc_xxx   # value from Step 6
sed "s/<cldrsrc-id>/$(echo $CLOUD_ID | tr _ -)/g" sample-envoy-gateway.yaml \
  | kubectl apply -f -
```

Retrieve the gateway's load-balancer hostname (needed in the next step):

```shell
kubectl get gateway gateway -n anyscale-operator \
  -o jsonpath='{.status.addresses[0].value}'
```

## Step 8: Install the Anyscale Operator

```shell
helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update
```

Then use the helm command from terraform output, replacing `<cloud-deployment-id>` with the ID from Step 6 and `<gateway-lb-address>` with the value from Step 7:

```shell
helm upgrade anyscale-operator anyscale/anyscale-operator \
  --set-string global.cloudDeploymentId=<cloud-deployment-id> \
  --set-string global.controlPlaneURL=https://console.azure.anyscale.com \
  --set-string global.cloudProvider=azure \
  --set-string global.auth.iamIdentity=<client-id> \
  --set-string global.auth.audience=api://086bc555-6989-4362-ba30-fded273e432b/.default \
  --set-string workloads.serviceAccount.name=anyscale-operator \
  --set networking.gateway.enabled=true \
  --set-string networking.gateway.name=gateway \
  --set-string networking.gateway.namespace=anyscale-operator \
  --set-string networking.gateway.apiVersion=gateway.networking.k8s.io/v1 \
  --set-string networking.gateway.hostname=<gateway-lb-address> \
  --namespace anyscale-operator \
  --create-namespace \
  -i
```

For custom GPU types (other than T4), copy `sample-custom_values.yaml` to `custom_values.yaml`, edit it, and add `-f custom_values.yaml` to the helm command.

## Teardown

To destroy all resources:

```shell
# Remove helm releases and Gateway resources first
helm uninstall anyscale-operator -n anyscale-operator
helm uninstall nvdp -n nvidia-device-plugin
kubectl delete -f sample-envoy-gateway.yaml --ignore-not-found
helm uninstall eg -n envoy-gateway-system

# Then destroy terraform resources
terraform destroy
```

## Troubleshooting

If the user hits issues, check:
- `kubectl get nodes` - Verify nodes are ready
- `kubectl get pods -A` - Check for failing pods
- `az aks show -g <rg> -n <cluster>` - Verify cluster state
- Ensure the Azure subscription has quota for the requested VM sizes
