[![Terraform Version][badge-terraform]](https://github.com/hashicorp/terraform/releases)
[![AWS Provider Version][badge-tf-aws]](https://github.com/terraform-providers/terraform-provider-aws/releases)

# Anyscale Azure AKS Example - Public Networking
This example creates the resources to run Anyscale on Azure AKS with either public or private networking.

The content of this module should be used as a starting point and modified to your own security and infrastructure
requirements.

## Getting Started

### Claude Code Guided Deployment

If you have [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed, you can use the built-in skill to get interactive, step-by-step deployment guidance:

```shell
claude
# Then type: /deploy-azure-aks
```

This will walk you through the full deployment process, check your prerequisites, and help you configure variables. You can also jump to a specific step (e.g., `/deploy-azure-aks envoy` or `/deploy-azure-aks register`).

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

Using the output from the Terraform modules, register the Anyscale Cloud. Choose a name for your cloud in Anyscale in `<anyscale_cloud_name`. It should look sonething like:

```shell
anyscale cloud register \
  --name <anyscale_cloud_name> \
  --region ... \
  --provider azure \
  --compute-stack k8s \
  --azure-tenant-id ... \
  --anyscale-operator-iam-identity ...  \
  --cloud-storage-bucket-name 'azure://...' \
  --cloud-storage-bucket-endpoint 'https://....blob.core.windows.net'
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

Retrieve the Gateway's load-balancer address for the operator install:

```shell
kubectl get gateway gateway -n anyscale-operator \
  -o jsonpath='{.status.addresses[0].value}'
```

### Install the Anyscale Operator

Update helm repo cache:

```
helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo update
```

Using the output from the `cloud register`, install the Anyscale Operator on the AKS Cluster. It should look someting like:

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

[optional] If you are using GPU types other than T4 follow these steps:
A sample file, `sample-custom_values.yaml` has been provided in this repo. Make a copy `custom_values.yaml` and update based on your GPU types before using.

```shell
helm upgrade anyscale-operator anyscale/anyscale-operator \
  ...
  -f custom_values.yaml \
  --create-namespace \
  -i
```

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
