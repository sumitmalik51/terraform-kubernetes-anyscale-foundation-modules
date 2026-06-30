# ============================================================
# FULL ANYSCALE AKS AUTOMATION
# ============================================================

$ErrorActionPreference = 'Stop'

# ============================================================
# CONFIGURATION
# ============================================================

$DeploymentID = $env:DeploymentID
$AppID = $env:AppID
$AppSecret = $env:AppSecret
$AzureTenantID = $env:AzureTenantID
$ODL_USER_EMAIL = $env:AzureUserName

$AzureSubscriptionID = $env:AzureSubscriptionID
$AzurePassword = $env:AzurePassword
$azuserobjectid = $env:azuserobjectid


# Azure
$AZURE_SUBSCRIPTION_ID = $env:AzureSubscriptionID
$AZURE_TENANT_ID       = $env:AzureTenantID
$AZURE_REGION          = "spaincentral"

# ODL User
az login --service-principal --username $env:AppID --password $env:AppSecret --tenant $env:AzureTenantID



$ANYSCALE_TOKEN = "aph0_CkcwRQIhAPzpIaOksPWsI3FodvTurTWzyJiG0vqhrY08EZ6SNAoVAiAtpBUsp-SNl2D9i1cDJCwnjtAphlTqdqi90VDXKuVy1hJjEiBYxbBY2YXzpxp8ZGKe7vL-m0Nx5sa0LlC_ErD_lHBUpxgBIh51c3JfdmNkZG50amh6ZWp5N210MjdzaXB2NjI0aTc6DAjun8XVBhCIp5_DAkIMCMLP6tEGEIinn8MC8gEA"
$ANYSCALE_HOST  = "https://console.anyscale.com"

# ============================================================
# DERIVED VALUES
# ============================================================

$ODL_USERNAME = $ODL_USER_EMAIL.Split("@")[0]

$LabId = ($ODL_USERNAME -replace "odl_user_", "")

$AKS_NAME  = "aks-$LabId"
$CloudName = "${ODL_USERNAME}_cloud"

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "ODL Username : $ODL_USERNAME"
Write-Host "AKS Name     : $AKS_NAME"
Write-Host "Cloud Name   : $CloudName"
Write-Host "========================================" -ForegroundColor Green
Write-Host ""

# ============================================================
# ANYSCALE HELPER FUNCTION
# ============================================================

function Invoke-AnyscaleCommand {

    param (
        [string]$Command
    )

    $guid = [guid]::NewGuid().ToString()

    $stdoutFile = "$env:TEMP\anyscale_stdout_$guid.txt"
    $stderrFile = "$env:TEMP\anyscale_stderr_$guid.txt"

    $cmdCommand = @"
set ANYSCALE_HOST=$ANYSCALE_HOST&& set ANYSCALE_CLI_TOKEN=$ANYSCALE_TOKEN&& $Command
"@

    Write-Host ""
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host "Executing Anyscale Command"
    Write-Host "==================================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host $cmdCommand -ForegroundColor DarkGray
    Write-Host ""

    $process = Start-Process `
        -FilePath "cmd.exe" `
        -ArgumentList "/c $cmdCommand" `
        -NoNewWindow `
        -Wait `
        -PassThru `
        -RedirectStandardOutput $stdoutFile `
        -RedirectStandardError $stderrFile

    $stdout = ""
    $stderr = ""

    if (Test-Path $stdoutFile) {
        $stdout = Get-Content $stdoutFile -Raw
    }

    if (Test-Path $stderrFile) {
        $stderr = Get-Content $stderrFile -Raw
    }

    if (![string]::IsNullOrWhiteSpace($stdout)) {

        Write-Host ""
        Write-Host "---------------- STDOUT ----------------" -ForegroundColor Green
        Write-Host $stdout
    }

    if (![string]::IsNullOrWhiteSpace($stderr)) {

        Write-Host ""
        Write-Host "---------------- STDERR ----------------" -ForegroundColor Yellow
        Write-Host $stderr
    }

    Start-Sleep -Milliseconds 500

    if (Test-Path $stdoutFile) {
        Remove-Item $stdoutFile -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $stderrFile) {
        Remove-Item $stderrFile -Force -ErrorAction SilentlyContinue
    }

    if ($process.ExitCode -ne 0) {

        Write-Host ""
        Write-Host "==================================================" -ForegroundColor Red
        Write-Host "Anyscale Command Failed"
        Write-Host "==================================================" -ForegroundColor Red

        Write-Host ""
        Write-Host "Exit Code: $($process.ExitCode)" -ForegroundColor Red

        if (![string]::IsNullOrWhiteSpace($stderr)) {
            throw $stderr
        }
        else {
            throw "Anyscale command failed with exit code $($process.ExitCode)"
        }
    }

    Write-Host ""
    Write-Host "Command completed successfully." -ForegroundColor Green
    Write-Host ""

    return ($stdout + "`n" + $stderr)
}

# ============================================================
# CLONE REPOSITORY
# ============================================================

$RepoUrl = "https://github.com/sumitmalik51/terraform-kubernetes-anyscale-foundation-modules"
$RepoFolder = "terraform-kubernetes-anyscale-foundation-modules"

if (!(Test-Path $RepoFolder)) {

    Write-Host "Cloning repository..." -ForegroundColor Yellow

    git clone $RepoUrl
}

# ============================================================
# MOVE TO TERRAFORM DIRECTORY
# ============================================================

Set-Location "$RepoFolder\examples\azure\aks-new_cluster"

# ============================================================
# UPDATE variables.tf
# ============================================================

Write-Host "Updating variables.tf..." -ForegroundColor Yellow

$variablesFile = ".\variables.tf"

$content = Get-Content $variablesFile -Raw

$content = $content.Replace(
    'default = "replacesubscription"',
    "default = `"$AZURE_SUBSCRIPTION_ID`""
)

$content = $content.Replace(
    'default = "replaceregion"',
    "default = `"$AZURE_REGION`""
)

$content = $content.Replace(
    'default = "replacetenantid"',
    "default = `"$AZURE_TENANT_ID`""
)

$content = $content.Replace(
    'default = "replaceaksname"',
    "default = `"$AKS_NAME`""
)

Set-Content -Path $variablesFile -Value $content





Write-Host "variables.tf updated successfully." -ForegroundColor Green

# ============================================================
# TERRAFORM INIT/APPLY
# ============================================================

terraform init

terraform apply -auto-approve | Tee-Object terraform-output.txt

if ($LASTEXITCODE -ne 0) {
    throw "Terraform apply failed with exit code $LASTEXITCODE"
}

# ============================================================
# READ TERRAFORM OUTPUT
# ============================================================

$content = Get-Content ".\terraform-output.txt" -Raw

function Get-RegexValue {

    param (
        [string]$Pattern
    )

    $match = [regex]::Match($content, $Pattern)

    if ($match.Success) {
        return $match.Groups[1].Value.Trim()
    }

    return $null
}

# ============================================================
# PARSE VALUES
# ============================================================

$AKS_CLUSTER_NAME = Get-RegexValue 'azure_aks_cluster_name = "([^"]+)"'
$RESOURCE_GROUP   = Get-RegexValue 'azure_resource_group_name = "([^"]+)"'

$Region = Get-RegexValue '--region\s+([^\s]+)'
$TenantId = Get-RegexValue '--azure-tenant-id\s+([^\s]+)'
$OperatorIdentity = Get-RegexValue '--anyscale-operator-iam-identity\s+([^\s]+)'

$StorageBucketName = Get-RegexValue "--cloud-storage-bucket-name '([^']+)'"
$StorageBucketEndpoint = Get-RegexValue "--cloud-storage-bucket-endpoint '([^']+)'"

$IamIdentity = Get-RegexValue '--set-string global.auth.iamIdentity=([^\s]+)'
$OperatorClientId = Get-RegexValue 'anyscale_operator_client_id = "([^"]+)"'

# ============================================================
# AKS LOGIN
# ============================================================

az aks get-credentials `
    --resource-group $RESOURCE_GROUP `
    --name $AKS_CLUSTER_NAME `
    --overwrite-existing

# ============================================================
# HELM REPOS
# ============================================================

helm repo add nginx https://kubernetes.github.io/ingress-nginx
helm repo add anyscale https://anyscale.github.io/helm-charts
helm repo add nvdp https://nvidia.github.io/k8s-device-plugin

helm repo update

# ============================================================
# INSTALL INGRESS NGINX
# ============================================================

helm upgrade ingress-nginx nginx/ingress-nginx `
    --version 4.12.1 `
    --namespace ingress-nginx `
    --values sample-values_nginx.yaml `
    --create-namespace `
    --install

# ============================================================
# INSTALL NVIDIA PLUGIN
# ============================================================

helm upgrade nvdp nvdp/nvidia-device-plugin `
    --namespace nvidia-device-plugin `
    --version 0.17.1 `
    --values sample_values_nvdp.yaml `
    --create-namespace `
    --install



# ============================================================
# REGISTER CLOUD
# ============================================================

try {
    $registrationOutput = Invoke-AnyscaleCommand "anyscale cloud register --name $CloudName --region $Region --provider azure --compute-stack k8s --azure-tenant-id $TenantId --anyscale-operator-iam-identity $OperatorIdentity --cloud-storage-bucket-name `"$StorageBucketName`" --cloud-storage-bucket-endpoint `"$StorageBucketEndpoint`""
} catch {
    # If cloud already exists (409 conflict), look up the existing cloud
    if ($_.Exception.Message -match '409|already exists|conflict') {
        Write-Host "Cloud '$CloudName' already exists. Retrieving existing cloud info..." -ForegroundColor Yellow
        $registrationOutput = Invoke-AnyscaleCommand "anyscale cloud list --name $CloudName"
    } else {
        throw
    }
}

# ============================================================
# EXTRACT DEPLOYMENT ID
# ============================================================

$idMatch = [regex]::Match(
    $registrationOutput,
    'cldrsrc_[a-zA-Z0-9]+'
)

if (-not $idMatch.Success) {
    throw "Cloud Deployment ID not found."
}

$CloudDeploymentId = $idMatch.Value

Write-Host ""
Write-Host "Cloud Deployment ID: $CloudDeploymentId" -ForegroundColor Green
Write-Host ""

# ============================================================
# INSTALL ANYSCALE OPERATOR
# ============================================================

helm upgrade anyscale-operator anyscale/anyscale-operator `
    --version 1.5.1 `
    --set-string global.cloudDeploymentId=$CloudDeploymentId `
    --set-string global.controlPlaneURL=https://console.anyscale.com `
    --set-string global.cloudProvider=azure `
    --set-string global.auth.iamIdentity=$IamIdentity `
    --set-string global.auth.audience=api://086bc555-6989-4362-ba30-fded273e432b/.default `
    --set-string workloads.serviceAccount.name=anyscale-operator `
    --set-string workloads.serviceAccount.annotations."azure\.workload\.identity/client-id"=$OperatorClientId `
    --namespace anyscale-operator `
    --create-namespace `
    --wait `
    -i

# ============================================================
# WORKLOAD IDENTITY FOR RAY PODS
# The Anyscale operator schedules Ray cluster/workspace pods under the
# namespace's *default* ServiceAccount. Annotate it with the operator
# managed-identity client-id so the azure-workload-identity webhook injects
# AZURE_CLIENT_ID / the federated token into those pods. The matching
# federated credential (anyscale-default-fed) is created by Terraform.
# Without this, blob auth fails: "WorkloadIdentityCredential: no client ID specified".
# ============================================================
kubectl -n anyscale-operator annotate serviceaccount default `
    "azure.workload.identity/client-id=$OperatorClientId" --overwrite

$configfile = ".\compute-config.yaml"

$configcontent = Get-Content $configfile -Raw



$configcontent = $configcontent.Replace(
    'cloud: replacecloud',
    "cloud: $CloudName"
)

Set-Content -Path $configfile -Value $configcontent






# ============================================================
# VALIDATION
# ============================================================

kubectl get nodes

kubectl get pods -A

kubectl get pods -n anyscale-operator

# ============================================================
# DONE
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Deployment Completed Successfully 🚀"
Write-Host "========================================" -ForegroundColor Green






# ============================================================
# ENABLE A10 GPU SUPPORT
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Enabling A10 GPU Support"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# CREATE CUSTOM VALUES FILE
# ============================================================

$customValuesFile = "anyscale-a10-values.yaml"

$yaml = @"
global:
  cloudProvider: azure
  cloudDeploymentId: $CloudDeploymentId
  controlPlaneURL: https://console.anyscale.com

  auth:
    audience: api://086bc555-6989-4362-ba30-fded273e432b/.default
    iamIdentity: $IamIdentity

workloads:
  serviceAccount:
    name: anyscale-operator
    annotations:
      azure.workload.identity/client-id: $OperatorClientId
  instanceTypes:
    additional:

      36CPU-288GB-1xA10:
        resources:
          # 34 (not 36): leave headroom below the 36 vCPU node for AKS system
          # reservation + daemonsets, otherwise the pod never schedules.
          CPU: 34
          GPU: 1
          memory: 288Gi
          accelerators:
            - A10G

patches:
  - kind: Pod
    selector: "anyscale.com/accelerator-type"

    patch:
      - op: add
        path: /spec/tolerations/-

        value:
          key: nvidia.com/gpu
          operator: Equal
          value: present
          effect: NoSchedule
"@

$yaml | Out-File $customValuesFile -Encoding utf8

Write-Host "Generated: $customValuesFile" -ForegroundColor Green

# ============================================================
# DRY RUN
# ============================================================

Write-Host ""
Write-Host "Running Helm dry-run..." -ForegroundColor Yellow

helm upgrade anyscale-operator anyscale/anyscale-operator `
    -n anyscale-operator `
    --version 1.5.1 `
    -f $customValuesFile `
    --reuse-values `
    --dry-run=server

if ($LASTEXITCODE -ne 0) {
    throw "Helm dry-run failed."
}

# ============================================================
# APPLY OPERATOR UPGRADE
# ============================================================

Write-Host ""
Write-Host "Applying A10 operator upgrade..." -ForegroundColor Yellow

helm upgrade anyscale-operator anyscale/anyscale-operator `
    -n anyscale-operator `
    --version 1.5.1 `
    -f $customValuesFile `
    --reuse-values `
    --force-conflicts `
    --wait

if ($LASTEXITCODE -ne 0) {
    throw "Failed to upgrade Anyscale operator with A10 support."
}

# ============================================================
# VALIDATE INSTANCE TYPES
# ============================================================

Write-Host ""
Write-Host "Validating A10 registration..." -ForegroundColor Yellow

kubectl -n anyscale-operator get cm instance-types `
    -o jsonpath='{.data.instance_types\.yaml}'

# ============================================================
# VALIDATE PATCHES
# ============================================================

Write-Host ""
Write-Host "Validating GPU toleration patches..." -ForegroundColor Yellow

kubectl -n anyscale-operator get cm patches `
    -o jsonpath='{.data.patches\.yaml}'

# ============================================================
# VALIDATE OPERATOR HEALTH
# ============================================================

Write-Host ""
Write-Host "Checking operator rollout..." -ForegroundColor Yellow

kubectl -n anyscale-operator rollout status deploy/anyscale-operator

kubectl get pods -n anyscale-operator

# ============================================================
# VALIDATE AKS GPU NODEPOOL
# ============================================================

Write-Host ""
Write-Host "Checking A10 nodepool autoscaling..." -ForegroundColor Yellow

az aks nodepool show `
    -g $RESOURCE_GROUP `
    --cluster-name $AKS_CLUSTER_NAME `
    -n gpua10 `
    --query "{enableAutoScaling:enableAutoScaling,minCount:minCount,maxCount:maxCount}" `
    -o table

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "A10 GPU Enablement Completed"
Write-Host "========================================" -ForegroundColor Green



# ============================================================
# WORKSPACE SETUP (CPU-only -- no GPU assigned)
# ============================================================
#
# Spin up a development workspace WITHOUT a GPU: enough to load code, install
# deps, and iterate. GPU nodes are added back only when serving the
# SentimentClassifier / Summarizer replicas. These commands only *create* the
# workspace -- it is started manually afterwards (see the start command below).
# ============================================================

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Workspace Setup (CPU-only)"
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# -- Generate the CPU-only compute config (cloud bound dynamically) ----------
$WorkspaceComputeConfigFile = "workspace-compute-config.yaml"

$workspaceComputeYaml = @"
cloud: $CloudName

# CPU-only control plane + workers. min_nodes: 0 so the workspace costs nothing
# extra when idle; workers scale up on demand and back down to zero.
head_node:
  instance_type: 8CPU-32GB

worker_nodes:
  - instance_type: 8CPU-32GB
    min_nodes: 0
    max_nodes: 4
"@

$workspaceComputeYaml | Out-File $WorkspaceComputeConfigFile -Encoding utf8

Write-Host "Generated: $WorkspaceComputeConfigFile" -ForegroundColor Green

# -- Generate requirements.txt for the workspace image -----------------------
$RequirementsFile = "requirements.txt"

$requirementsContent = @"
transformers>=4.40.0
numpy>=1.24.0
fastapi>=0.100.0
requests>=2.28.0
"@

$requirementsContent | Out-File $RequirementsFile -Encoding utf8

Write-Host "Generated: $RequirementsFile" -ForegroundColor Green

# -- 1. Create the compute configuration -------------------------------------
try {
    Invoke-AnyscaleCommand "anyscale compute-config create -n workspace-compute-config -f workspace-compute-config.yaml"
} catch {
    if ($_.Exception.Message -match '409|already exists|conflict') {
        Write-Host "Compute config 'workspace-compute-config' already exists. Skipping creation." -ForegroundColor Yellow
    } else {
        throw
    }
}

# -- 2. Create the workspace (CPU-only; not started) -------------------------
try {
    Invoke-AnyscaleCommand "anyscale workspace_v2 create --name multi-model-pipeline-workspace --image-uri anyscale/ray-llm:2.56.0-py312-cu130 --compute-config workspace-compute-config:1 --requirements requirements.txt"
} catch {
    if ($_.Exception.Message -match '409|already exists|conflict') {
        Write-Host "Workspace 'multi-model-pipeline-workspace' already exists. Skipping creation." -ForegroundColor Yellow
    } else {
        throw
    }
}

# -- 3. Start it manually ----------------------------------------------------
# `workspace_v2 create` only registers the workspace; it does not start it.
# Start it from the Anyscale console, or via the CLI shown below.
Write-Host ""
Write-Host "Workspace 'multi-model-pipeline-workspace' created (not started)." -ForegroundColor Green
Write-Host "Start it manually when ready:" -ForegroundColor Cyan
Write-Host "    anyscale workspace_v2 start -n multi-model-pipeline-workspace" -ForegroundColor White




