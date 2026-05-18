# Anyscale Azure AKS Example
This example creates the resources to run Anyscale on Azure AKS with public networking.

The content of this module should be used as a starting point and modified to your own security and infrastructure
requirements.

## Getting Started

### Claude Code Guided Deployment

If you have [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed, you can use the built-in skill to get interactive, step-by-step deployment guidance:

```shell
claude
# Then type: /deploy-azure-aks
```

This will walk you through the full deployment process, check your prerequisites, and help you configure variables. You can also jump to a specific step (e.g., `/deploy-azure-aks envoy`, `/deploy-azure-aks register`, or `/deploy-azure-aks pvc`).

### Prerequisites

* [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/)
  * [Sign into the Azure CLI](https://learn.microsoft.com/en-us/cli/azure/get-started-with-azure-cli#sign-into-the-azure-cli)
* [kubectl CLI](https://kubernetes.io/docs/tasks/tools/)
* [helm CLI](https://helm.sh/docs/intro/install/)
* [Anyscale CLI](https://docs.anyscale.com/reference/quickstart-cli/) (> v0.26.24)

### Creating Anyscale Resources

Steps for deploying Anyscale resources via Terraform:

* Review variables.tf and (optionally) create a `terraform.tfvars` file to override any of the defaults.
e.g. 
```hcl
azure_tenant_id       = "" # az account show --query tenantId -o tsv
azure_subscription_id = ""
azure_location        = ""
aks_cluster_name      = ""

# (Optional) Override the default GPU node pools. The default provisions
# both T4 and A100 pools; the example below restricts it to T4 only.
# Set to `{}` for a CPU-only cluster. Each entry's `name` must be lowercase
# alphanumeric and <= 8 characters (spot pools append "spot").
gpu_pool_configs = {
  T4 = {
    name         = "gput4"
    vm_size      = "Standard_NC16as_T4_v3"
    product_name = "NVIDIA-T4"
    gpu_count    = "1"
  }
}
```

* Apply the terraform

```shell
terraform init
terraform plan
terraform apply
```

If you are using a `tfvars` file, you will need to update the above commands accordingly.
Note the output from Terraform which includes example cloud registration, helm commands and the command to get the AKS credentials you will use below.

### Install the Kubernetes Requirements

The Anyscale Operator requires the following components:
* [Envoy Gateway](https://gateway.envoyproxy.io/) (other Gateway API implementations may be possible but are untested). Requires Kubernetes 1.30 or later.
* (Optional) [Nvidia device plugin](https://github.com/NVIDIA/k8s-device-plugin/tree/main?tab=readme-ov-file#deployment-via-helm) (required if utilizing GPU nodes)

**Note:** Ensure that you are authenticated to the AKS cluster for the remaining steps. You can use the command from the Terraform output:

```shell
# From terraform output: aks_get_credentials_command
az aks get-credentials --resource-group <azure_resource_group_name> --name <aks_cluster_name> --overwrite-existing
```

#### Install Envoy Gateway

Install the Envoy Gateway Helm chart:

```shell
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.0 \
  --namespace envoy-gateway-system \
  --create-namespace

kubectl wait --for=condition=available deployment/envoy-gateway \
  -n envoy-gateway-system --timeout=120s
```

A sample manifest, `sample-envoy-gateway.yaml`, has been provided in this repo. It contains three resources: an `EnvoyProxy` (with Azure load-balancer annotations), a `GatewayClass` named `eg`, and a `Gateway` named `gateway` in the `anyscale-operator` namespace with HTTP/HTTPS listeners.

The Gateway listeners reference TLS Secrets whose names embed the Anyscale cloud deployment ID, so the manifest is applied **after** running `anyscale cloud register` further down. For now, only the helm install above is needed; the [Apply Envoy Gateway Resources](#apply-envoy-gateway-resources) step below picks it back up once you have the cloud deployment ID.

#### (Optional) Install the Nvidia device plugin

A sample file, `sample-values_nvdp.yaml` has been provided in this repo. Please review for AKS requirements before using.

1. Create a YAML values file named: `values_nvdp.yaml`
2. Update the content with the following:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: "kubernetes.azure.com/accelerator"
          operator: Exists
tolerations:
  - key: nvidia.com/gpu
    operator: Exists
    effect: NoSchedule
  - key: node.anyscale.com/capacity-type
    operator: Exists
    effect: NoSchedule
  - key: node.anyscale.com/accelerator-type
    operator: Exists
    effect: NoSchedule
  - key: kubernetes.azure.com/scalesetpriority
    operator: Exists
    effect: NoSchedule
```

3. Run:

```shell
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin
helm upgrade nvdp nvdp/nvidia-device-plugin \
  --namespace nvidia-device-plugin \
  --version 0.17.1 \
  --values values_nvdp.yaml \
  --create-namespace \
  --install
```

### Register the Anyscale Cloud

Ensure that you are logged into Anyscale with valid CLI credentials. (`anyscale login`)

Using the output from the Terraform modules, register the Anyscale Cloud. Choose a name for your cloud in Anyscale in `<anyscale_cloud_name>`. It should look something like:

```shell
anyscale cloud register \
  --name <anyscale_cloud_name> \
  --region ... \
  --provider azure \
  --compute-stack k8s \
  --azure-tenant-id ... \
  --anyscale-operator-iam-identity ...  \
  --cloud-storage-bucket-name 'abfss://<container>@<storage-account>.dfs.core.windows.net' \
  --cloud-storage-bucket-endpoint 'https://<storage-account>.blob.core.windows.net'
```

Note the **cloud deployment ID** (`cldrsrc_...`) printed at the end — you'll need it for the next two steps.

### Apply Envoy Gateway Resources

Create the operator namespace if it doesn't already exist:

```shell
kubectl create namespace anyscale-operator
```

Substitute `<cldrsrc-id>` in `sample-envoy-gateway.yaml` with the **dash-form** of the cloud deployment ID from the previous step. Kubernetes Secret names can't contain underscores, so the operator stores the cert as `anyscale-cldrsrc-<dash-form>-certificate`. The easiest way is to pipe through `sed` and `tr`:

```shell
CLOUD_ID=cldrsrc_xxx  # value from `anyscale cloud register`
sed "s/<cldrsrc-id>/$(echo $CLOUD_ID | tr _ -)/g" sample-envoy-gateway.yaml \
  | kubectl apply -f -
```

Wait for the Gateway's load-balancer to be provisioned (typically 10-30s), then capture its address for the operator install:

```shell
kubectl wait --for=condition=Programmed gateway/gateway \
  -n anyscale-operator --timeout=180s

GATEWAY_ADDRESS=$(kubectl get gateway gateway -n anyscale-operator \
  -o jsonpath='{.status.addresses[0].value}')
echo "Gateway address: $GATEWAY_ADDRESS"
```

### Install the Anyscale Operator

Update helm repo cache:

```
helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update
```

Using the output from the `cloud register`, install the Anyscale Operator on the AKS Cluster. It should look something like:

```shell
helm upgrade anyscale-operator anyscale/anyscale-operator \
  --set-string global.cloudDeploymentId=cldrsrc_... \
  --set-string global.cloudProvider=azure \
  --set-string global.auth.iamIdentity=... \
  --set-string global.auth.audience=api://.../.default \
  --set-string workloads.serviceAccount.name=anyscale-operator \
  --set networking.gateway.enabled=true \
  --set-string networking.gateway.name=gateway \
  --set-string networking.gateway.namespace=anyscale-operator \
  --set-string networking.gateway.apiVersion=gateway.networking.k8s.io/v1 \
  --set-string networking.gateway.hostname=<gateway-lb-address> \
  --namespace anyscale-operator \
  --create-namespace \
  --wait \
  -i
```

Replace `<gateway-lb-address>` with the value returned by the `kubectl get gateway` command above.

**(Optional)** If you are using GPU types other than T4, follow these steps. A sample file, `sample-custom_values.yaml` has been provided in this repo. Make a copy as `custom_values.yaml` and update based on your GPU types before using.

```shell
helm upgrade anyscale-operator anyscale/anyscale-operator \
  ...
  -f custom_values.yaml \
  --create-namespace \
  -i
```

### (Optional) Enable Head Node Fault Tolerance (HNFT)

HNFT externalizes Ray GCS state to a Redis-compatible store so the Ray head node can restart without losing cluster state. See the [Anyscale HNFT docs](https://docs.anyscale.com/administration/resource-management/head-node-fault-tolerance) for background.

On Kubernetes, Anyscale does **not** auto-provision Redis. You provide one, then opt individual services into HNFT via their service config. This example supports an opt-in in-cluster Redis (bitnami/redis) for the backend.

To enable, set in your `terraform.tfvars`:

```hcl
enable_hnft = true

# Optional overrides — defaults shown:
# hnft_redis_namespace     = "ray-system"   # K8s namespace for the in-cluster Redis
# hnft_redis_chart_version = null           # pin a bitnami/redis chart version
```

Re-run `terraform apply` (safe against an existing cluster — no Azure resources are added). Two new outputs become available: `redis_helm_install_command` and `hnft_service_config_snippet`.

#### Deploy the in-cluster Redis

```shell
$(terraform output -raw redis_helm_install_command)
```

The helm command uses `--wait`, so it returns only after the Redis pods are Ready. The chart deploys a single primary + 1 replica (matching the HNFT doc's "single shard + ≥1 replica" requirement), auth disabled. The primary is reachable in-cluster at `redis-master.ray-system.svc.cluster.local:6379`.

#### Enable HNFT per service

HNFT is enabled per workload, not cloud-wide. For each Anyscale service that should be HNFT-protected, paste this block into its service config:

```shell
terraform output -raw hnft_service_config_snippet
# ray_gcs_external_storage_config:
#   enabled: true
#   address: redis-master.ray-system.svc.cluster.local:6379
```

Services that don't include this block are unaffected — they run without HNFT as before.

#### Caveats

- The in-cluster Redis here shares failure domain with the AKS cluster — it protects against head-pod restarts, not full cluster loss. For production, run Azure Cache for Redis in the same VNet and replace the `address` value in your service configs with that endpoint.
- Auth is disabled because Anyscale's documented `address` schema (`host:port` or `rediss://host:port`) has no credential field. Network reachability within the cluster is the isolation boundary.
- No TLS in-cluster. Use Azure Cache for Redis with TLS + the `rediss://` scheme for an encrypted path; set `certificate_path` per service if the cert is private.

### (Optional) Enable Azure Blob CSI PVC for Workloads

Anyscale workloads can mount Azure Blob storage as shared persistent volumes via the Azure Blob CSI driver — useful for shared model artifacts, datasets, and checkpoints accessible from any Ray node. See the [Anyscale Azure PVC docs](https://docs.anyscale.com/clouds/azure/pvc) for the full background.

This module supports it out of the box behind the `enable_blob_driver` variable. When enabled, terraform:

1. Toggles `storage_profile.blob_driver_enabled = true` on the AKS cluster.
2. Grants four role assignments on the Anyscale storage account — the two CSI driver components authenticate as different identities and both need access:
   - **AKS control-plane (SystemAssigned) identity** — used by `csi-blob-controller` for dynamic container provisioning. Gets `Storage Blob Data Contributor` + `Storage Account Key Operator Service Role`.
   - **AKS kubelet (UserAssigned `<cluster>-agentpool`) identity** — used by `csi-blob-node` for pod-runtime mount. Gets the same two roles.

   Granting only one of the two identities causes either a 3-minute provisioning loop with 403 errors (controller can't create the container) or AADSTS70025 mount failures at pod startup (kubelet can't authenticate via MSI). Both are required.

To enable, set in your `terraform.tfvars`:

```hcl
enable_blob_driver = true
```

Then re-run `terraform apply` (safe to run against an existing cluster; only adds the role assignments).

#### When to create the PVC

You have two options:

- **Default — create now**: apply the PVC right after operator install (steps below). The PVC is ready by the time you deploy your first workload.
- **Create later**: skip this section for now. The terraform helper output stays available, so when you decide you want shared storage, come back and run the same commands. The cluster, CSI driver, and role assignments are already in place from `terraform apply` — only the K8s-side PVC apply + cloud-side registration are deferred.

The steps below apply to the "create now" path. If you're going with "create later", just bookmark this section and come back.

#### Apply the StorageClass + PVC

A sample manifest, `sample-blob-pvc.yaml`, is provided. It contains a `StorageClass` (`blobfuse-csi`) backed by the storage account terraform already provisioned, and a `PersistentVolumeClaim` (`anyscale-shared-fuse`, ReadWriteMany, 100 GiB) in the `anyscale-operator` namespace.

The easiest way to apply it is via the `pvc_apply_command` terraform output, which substitutes the storage-account and resource-group placeholders for you:

```shell
$(terraform output -raw pvc_apply_command)
```

Or substitute manually:

```shell
SA=$(terraform output -raw azure_storage_account_name)
RG=$(terraform output -raw azure_resource_group_name)
sed -e "s/<storage-account>/$SA/g" -e "s/<resource-group>/$RG/g" sample-blob-pvc.yaml \
  | kubectl apply -f -
```

Verify the PVC reaches `Bound`:

```shell
kubectl get pvc anyscale-shared-fuse -n anyscale-operator
```

#### Register the PVC with the Anyscale cloud

Anyscale needs the PVC referenced on the cloud's resource spec for workloads to mount it. The Anyscale CLI offers two paths; pick whichever fits your flow:

**Option A — set it at register time** (cleanest, but requires creating the namespace + applying the PVC *before* `anyscale cloud register`):

```shell
anyscale cloud register \
  ... \
  --persistent-volume-claim anyscale-shared-fuse
```

Note: `--persistent-volume-claim` is mutually exclusive with `--nfs-mount-target` / `--nfs-mount-path` and `--csi-ephemeral-volume-driver`. Don't combine with `enable_nfs = true` on the same cloud.

**Option B — update an existing cloud via resources YAML**:

There's no direct flag for this on `anyscale cloud update`; you patch the cloud's full resource spec via `-f`. The resources file is a full replacement (not a partial patch) and must include every field currently on the resource. Run `anyscale cloud get --name <cloud-name>` to see the current spec, then save it as `resources.yaml` with `file_storage` added:

```yaml
- cloud_resource_id: cldrsrc_xxx                # from `anyscale cloud get`
  name: k8s-azure-<region>
  provider: AZURE
  compute_stack: K8S
  region: <region>
  object_storage:
    bucket_name: abfss://<container>@<storage-account>.dfs.core.windows.net
    endpoint: https://<storage-account>.blob.core.windows.net
  azure_config:
    tenant_id: <azure-tenant-id>
  kubernetes_config:
    anyscale_operator_iam_identity: <operator-principal-id>
  file_storage:                                 # the new bit
    persistent_volume_claim: anyscale-shared-fuse
```

Then apply (pass `-y` to skip the diff prompt):

```shell
anyscale cloud update --name <anyscale-cloud-name> -f resources.yaml -y
```

See the [CloudResource schema](https://docs.anyscale.com/reference/cloud#cloudresource) for the full structure of the resources file.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.0.0 |
| <a name="requirement_azurerm"></a> [azurerm](#requirement\_azurerm) | 4.26.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_azurerm"></a> [azurerm](#provider\_azurerm) | 4.26.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [azurerm_federated_identity_credential.anyscale_operator_fic](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/federated_identity_credential) | resource |
| [azurerm_kubernetes_cluster.aks](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/kubernetes_cluster) | resource |
| [azurerm_kubernetes_cluster_node_pool.gpu_ondemand](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/kubernetes_cluster_node_pool) | resource |
| [azurerm_kubernetes_cluster_node_pool.gpu_spot](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/kubernetes_cluster_node_pool) | resource |
| [azurerm_kubernetes_cluster_node_pool.ondemand_cpu](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/kubernetes_cluster_node_pool) | resource |
| [azurerm_kubernetes_cluster_node_pool.spot_cpu](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/kubernetes_cluster_node_pool) | resource |
| [azurerm_resource_group.rg](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/resource_group) | resource |
| [azurerm_role_assignment.anyscale_blob_contrib](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/role_assignment) | resource |
| [azurerm_storage_account.sa](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/storage_account) | resource |
| [azurerm_storage_container.blob](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/storage_container) | resource |
| [azurerm_subnet.nodes](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/subnet) | resource |
| [azurerm_user_assigned_identity.anyscale_operator](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/user_assigned_identity) | resource |
| [azurerm_virtual_network.vnet](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/resources/virtual_network) | resource |
| [azurerm_location.example](https://registry.terraform.io/providers/hashicorp/azurerm/4.26.0/docs/data-sources/location) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_azure_subscription_id"></a> [azure\_subscription\_id](#input\_azure\_subscription\_id) | (Required) Azure subscription ID | `string` | n/a | yes |
| <a name="input_aks_cluster_name"></a> [aks\_cluster\_name](#input\_aks\_cluster\_name) | (Optional) Name of the AKS cluster (and related resources). | `string` | `"anyscale-demo"` | no |
| <a name="input_anyscale_operator_namespace"></a> [anyscale\_operator\_namespace](#input\_anyscale\_operator\_namespace) | (Optional) Kubernetes namespace for the Anyscale operator. | `string` | `"anyscale-operator"` | no |
| <a name="input_azure_location"></a> [azure\_location](#input\_azure\_location) | (Optional) Azure region for all resources. | `string` | `"West US"` | no |
| <a name="input_cors_rule"></a> [cors\_rule](#input\_cors\_rule) | (Optional)<br>Object containing a rule of Cross-Origin Resource Sharing.<br>The default allows GET, POST, PUT, HEAD, and DELETE<br>access for the purpose of viewing logs and other functionality<br>from within the Anyscale Web UI (*.anyscale.com).<br><br>ex:<pre>cors_rule = {<br>  allowed_headers = ["*"]<br>  allowed_methods = ["GET", "POST", "PUT", "HEAD", "DELETE"]<br>  allowed_origins = ["https://*.anyscale.com"]<br>  expose_headers  = ["Accept-Ranges", "Content-Range", "Content-Length"]<br>}</pre> | <pre>object({<br>    allowed_headers    = list(string)<br>    allowed_methods    = list(string)<br>    allowed_origins    = list(string)<br>    expose_headers     = list(string)<br>    max_age_in_seconds = optional(number, 0)<br>  })</pre> | <pre>{<br>  "allowed_headers": [<br>    "*"<br>  ],<br>  "allowed_methods": [<br>    "GET",<br>    "POST",<br>    "PUT",<br>    "HEAD",<br>    "DELETE"<br>  ],<br>  "allowed_origins": [<br>    "https://*.anyscale.com"<br>  ],<br>  "expose_headers": [<br>    "Accept-Ranges",<br>    "Content-Range",<br>    "Content-Length"<br>  ]<br>}</pre> | no |
| <a name="input_node_group_gpu_types"></a> [node\_group\_gpu\_types](#input\_node\_group\_gpu\_types) | (Optional) The GPU types of the AKS nodes.<br>Possible values: ["T4", "A10", "A100", "H100"] | `list(string)` | <pre>[<br>  "T4",<br>  "A100"<br>]</pre> | no |
| <a name="input_tags"></a> [tags](#input\_tags) | (Optional) Tags applied to all taggable resources. | `map(string)` | <pre>{<br>  "Environment": "dev",<br>  "Test": "true"<br>}</pre> | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_aks_get_credentials_command"></a> [aks\_get\_credentials\_command](#output\_aks\_get\_credentials\_command) | The command to get the AKS cluster credentials. |
| <a name="output_anyscale_operator_client_id"></a> [anyscale\_operator\_client\_id](#output\_anyscale\_operator\_client\_id) | Client ID of the Azure User Assigned Identity created for the cluster. |
| <a name="output_anyscale_operator_principal_id"></a> [anyscale\_operator\_principal\_id](#output\_anyscale\_operator\_principal\_id) | Principal ID of the Azure User Assigned Identity created for the cluster. |
| <a name="output_anyscale_registration_command"></a> [anyscale\_registration\_command](#output\_anyscale\_registration\_command) | The Anyscale registration command. |
| <a name="output_azure_aks_cluster_name"></a> [azure\_aks\_cluster\_name](#output\_azure\_aks\_cluster\_name) | Name of the Azure AKS cluster created for the cluster. |
| <a name="output_azure_resource_group_name"></a> [azure\_resource\_group\_name](#output\_azure\_resource\_group\_name) | Name of the Azure Resource Group created for the cluster. |
| <a name="output_azure_storage_account_name"></a> [azure\_storage\_account\_name](#output\_azure\_storage\_account\_name) | Name of the Azure Storage Account created for the cluster. |
| <a name="output_helm_upgrade_command"></a> [helm\_upgrade\_command](#output\_helm\_upgrade\_command) | The helm upgrade command. |
<!-- END_TF_DOCS -->
