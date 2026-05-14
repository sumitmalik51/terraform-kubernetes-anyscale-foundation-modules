data "aws_subnet" "existing" {
  for_each = toset(var.existing_subnet_ids)
  id       = each.value
}

locals {
  kubernetes_zones = join(",", [for s in data.aws_subnet.existing : s.availability_zone])
}

locals {
  registration_command_parts = compact([
    "anyscale cloud register",
    "--name <anyscale_cloud_name>",
    "--region ${var.aws_region}",
    "--provider aws",
    "--compute-stack k8s",
    "--kubernetes-zones ${local.kubernetes_zones}",
    "--s3-bucket-id ${module.anyscale_s3.s3_bucket_id}",
    var.enable_efs ? "--efs-id ${module.anyscale_efs.efs_id}" : null,
    var.enable_s3_pvc ? "--persistent-volume-claim anyscale-shared-fuse" : null,
    var.enable_memorydb ? "--memorydb-cluster-id ${module.anyscale_memorydb.memorydb_cluster_id}" : null,
    "--anyscale-operator-iam-identity <node_IAM_role_arn>",
  ])

  helm_upgrade_command_parts = compact([
    "helm upgrade anyscale-operator anyscale/anyscale-operator",
    "--set-string global.cloudDeploymentId=<cloud-deployment-id>",
    "--set-string global.cloudProvider=aws",
    "--set-string global.aws.region=${var.aws_region}",
    "--set-string workloads.serviceAccount.name=anyscale-operator",
    "--set networking.gateway.enabled=true",
    "--set-string networking.gateway.name=gateway",
    "--set-string networking.gateway.namespace=anyscale-operator",
    "--set-string networking.gateway.apiVersion=gateway.networking.k8s.io/v1",
    "--set-string networking.gateway.hostname=<gateway-nlb-hostname>",
    "--namespace anyscale-operator",
    "--create-namespace",
    "-i"
  ])

  pv_pvc_yaml = <<-YAML
    apiVersion: v1
    kind: PersistentVolume
    metadata:
      name: anyscale-shared-s3
    spec:
      accessModes:
        - ReadWriteMany
      capacity:
        storage: 1200Gi
      storageClassName: ""
      claimRef:
        namespace: anyscale-operator
        name: anyscale-shared-fuse
      mountOptions:
        - allow-other
        - region ${var.aws_region}
        - prefix anyscale-shared/
      csi:
        driver: s3.csi.aws.com
        volumeHandle: anyscale-shared-s3-volume
        volumeAttributes:
          bucketName: ${module.anyscale_s3.s3_bucket_id}
          authenticationSource: driver
    ---
    apiVersion: v1
    kind: PersistentVolumeClaim
    metadata:
      name: anyscale-shared-fuse
      namespace: anyscale-operator
    spec:
      accessModes:
        - ReadWriteMany
      storageClassName: ""
      resources:
        requests:
          storage: 1200Gi
      volumeName: anyscale-shared-s3
  YAML
}

resource "local_file" "pv_pvc_yaml" {
  count = var.enable_s3_pvc ? 1 : 0

  filename = "${path.module}/generated/pv-pvc.yaml"
  content  = local.pv_pvc_yaml
}

output "anyscale_registration_command" {
  description = "The Anyscale registration command."
  value       = join(" \\\n\t", local.registration_command_parts)
}

output "helm_upgrade_command" {
  description = "The helm upgrade command."
  value       = join(" \\\n\t", local.helm_upgrade_command_parts)
}

output "s3_pvc_bucket_name" {
  description = "Name of the S3 bucket exposed as a PVC via the Mountpoint-for-S3 CSI driver. Only set when `enable_s3_pvc = true`."
  value       = var.enable_s3_pvc ? module.anyscale_s3.s3_bucket_id : null
}

output "s3_pvc_csi_driver_role_arn" {
  description = "IAM role ARN that the Mountpoint-for-S3 CSI driver pods should assume via EKS Pod Identity. Pass this to `aws eks create-pod-identity-association --role-arn`. Only set when `enable_s3_pvc = true`."
  value       = var.enable_s3_pvc ? aws_iam_role.s3_csi_driver[0].arn : null
}

output "memorydb_endpoint" {
  description = "MemoryDB cluster configuration endpoint as host:port. Only set when `enable_memorydb = true`."
  value       = var.enable_memorydb ? "${module.anyscale_memorydb.memorydb_cluster_endpoint_address}:${module.anyscale_memorydb.memorydb_cluster_endpoint_port}" : null
}

#####################################################################
# Rendered post-terraform deployment script — ordered list of every
# helm/kubectl/anyscale command to run after `terraform apply`.
# Because this example uses an existing EKS cluster, you'll need to
# substitute <eks_cluster_name>, <anyscale_cloud_name>, and
# <node_IAM_role_arn> placeholders before running.
#####################################################################

locals {
  deploy_script = <<-EOT
    #!/usr/bin/env bash
    # Anyscale on an existing EKS cluster — post-terraform deployment commands.
    #
    # Substitute <eks_cluster_name>, <anyscale_cloud_name>, and
    # <node_IAM_role_arn> below before running. Steps 5-8 also depend on
    # $CLOUD_DEPLOYMENT_ID (captured from step 1) and $GATEWAY_HOSTNAME
    # (captured from step 5).
    set -euo pipefail

    # ------------------------------------------------------------------
    # 1. Register the Anyscale cloud  (returns a cldrsrc_... id)
    # ------------------------------------------------------------------
    echo "==> Step 1/8: Registering the Anyscale cloud..."
    # Replace <anyscale_cloud_name> and <node_IAM_role_arn> below:
    register_output=$(${join(" \\\n      ", local.registration_command_parts)} 2>&1)
    echo "$register_output"
    export CLOUD_DEPLOYMENT_ID=$(echo "$register_output" | grep -oE 'cldrsrc_[a-zA-Z0-9]+' | head -1 || true)
    : "$${CLOUD_DEPLOYMENT_ID:?failed to capture cldrsrc_ id from registration output}"
    echo "    Captured CLOUD_DEPLOYMENT_ID=$CLOUD_DEPLOYMENT_ID"

    # ------------------------------------------------------------------
    # 2. Authenticate to the EKS cluster
    # ------------------------------------------------------------------
    echo "==> Step 2/8: Updating kubeconfig for cluster <eks_cluster_name>..."
    aws eks update-kubeconfig --region ${var.aws_region} --name <eks_cluster_name>

    # ------------------------------------------------------------------
    # 3. Cluster Autoscaler
    # ------------------------------------------------------------------
    echo "==> Step 3/8: Installing Cluster Autoscaler..."
    helm repo add autoscaler https://kubernetes.github.io/autoscaler 2>/dev/null || true
    helm repo update
    helm upgrade cluster-autoscaler autoscaler/cluster-autoscaler \
      --version 9.46.0 \
      --namespace kube-system \
      --set awsRegion=${var.aws_region} \
      --set autoDiscovery.clusterName=<eks_cluster_name> \
      --install

    # ------------------------------------------------------------------
    # 4. AWS Load Balancer Controller  (region + vpcId explicit so it
    #    does not need IMDSv2 access to introspect them)
    # ------------------------------------------------------------------
    echo "==> Step 4/8: Installing AWS Load Balancer Controller..."
    helm repo add eks https://aws.github.io/eks-charts 2>/dev/null || true
    helm repo update
    helm upgrade aws-load-balancer-controller eks/aws-load-balancer-controller \
      --version 1.13.2 \
      --namespace kube-system \
      --set clusterName=<eks_cluster_name> \
      --set region=${var.aws_region} \
      --set vpcId=${var.existing_vpc_id} \
      --install
%{if var.enable_s3_pvc~}

    # ------------------------------------------------------------------
    # 4a. (enable_s3_pvc = true) Install the Mountpoint-S3 CSI managed
    #     addon and bind it to the IAM role Terraform created.
    # ------------------------------------------------------------------
    echo "==> Step 4a/8: Installing Mountpoint-S3 CSI managed addon + Pod Identity Association..."
    aws eks create-addon \
      --cluster-name <eks_cluster_name> \
      --addon-name aws-mountpoint-s3-csi-driver \
      --resolve-conflicts OVERWRITE
    aws eks create-pod-identity-association \
      --cluster-name <eks_cluster_name> \
      --namespace kube-system \
      --service-account s3-csi-driver-sa \
      --role-arn ${aws_iam_role.s3_csi_driver[0].arn}
%{endif~}

    # ------------------------------------------------------------------
    # 5. Envoy Gateway + Anyscale gateway manifests
    #    (substitutes the cldrsrc slug into the gateway YAML on the fly
    #    so the TLS Secret refs are correct from the first apply)
    # ------------------------------------------------------------------
    echo "==> Step 5/8: Installing Envoy Gateway v1.7.0 and applying Anyscale gateway manifests..."
    helm upgrade eg oci://docker.io/envoyproxy/gateway-helm \
      --version v1.7.0 \
      --namespace envoy-gateway-system \
      --create-namespace \
      --install
    kubectl wait --for=condition=available deployment/envoy-gateway \
      -n envoy-gateway-system --timeout=120s

    SECRET_SLUG="$${CLOUD_DEPLOYMENT_ID//_/-}"   # cldrsrc_xxx → cldrsrc-xxx
    echo "    Substituting SECRET_SLUG=$SECRET_SLUG into sample-values_gateway.yaml..."
    sed "s/<cloud-deployment-id>/$${SECRET_SLUG}/g" sample-values_gateway.yaml | kubectl apply -f -

    echo "    Waiting for Gateway to be Programmed (up to 5 min)..."
    kubectl wait -n anyscale-operator --for=condition=Programmed gateway/gateway --timeout=300s
    export GATEWAY_HOSTNAME=$(kubectl get gateway gateway -n anyscale-operator \
      -o jsonpath='{.status.addresses[0].value}')
    echo "    Captured GATEWAY_HOSTNAME=$GATEWAY_HOSTNAME"
%{if var.enable_s3_pvc~}

    # ------------------------------------------------------------------
    # 6. Apply the Mountpoint-S3 PV/PVC  (enable_s3_pvc = true)
    # ------------------------------------------------------------------
    echo "==> Step 6/8: Applying S3 PersistentVolume + PersistentVolumeClaim..."
    kubectl apply -f ./generated/pv-pvc.yaml
    echo "    Waiting for PVC anyscale-shared-fuse to bind (up to 2 min)..."
    kubectl wait -n anyscale-operator --for=jsonpath='{.status.phase}'=Bound \
      pvc/anyscale-shared-fuse --timeout=120s
%{endif~}

    # ------------------------------------------------------------------
    # 7. Anyscale Operator
    # ------------------------------------------------------------------
    echo "==> Step 7/8: Installing the Anyscale Operator helm chart..."
    helm repo add anyscale https://anyscale.github.io/helm-charts 2>/dev/null || true
    helm repo update
    helm upgrade anyscale-operator anyscale/anyscale-operator \
      --set-string global.cloudDeploymentId="$CLOUD_DEPLOYMENT_ID" \
      --set-string global.cloudProvider=aws \
      --set-string global.aws.region=${var.aws_region} \
      --set-string workloads.serviceAccount.name=anyscale-operator \
      --set networking.gateway.enabled=true \
      --set-string networking.gateway.name=gateway \
      --set-string networking.gateway.namespace=anyscale-operator \
      --set-string networking.gateway.apiVersion=gateway.networking.k8s.io/v1 \
      --set-string networking.gateway.hostname="$GATEWAY_HOSTNAME" \
      --namespace anyscale-operator \
      --install \
      --wait --timeout 10m

    echo "    Waiting for the operator to create the head-node TLS Secret (up to 5 min)..."
    kubectl wait --for=create secret/anyscale-$${SECRET_SLUG}-certificate \
      -n anyscale-operator --timeout=300s

    # ------------------------------------------------------------------
    # 8. Verify
    # ------------------------------------------------------------------
    echo "==> Step 8/8: Verifying the deployment..."
    echo "    Cert Secret:"
    kubectl get secret "anyscale-$${SECRET_SLUG}-certificate" -n anyscale-operator
    echo "    Gateway listener status:"
    kubectl get gateway gateway -n anyscale-operator \
      -o jsonpath='{range .status.listeners[*]}{.name}: ResolvedRefs={.conditions[?(@.type=="ResolvedRefs")].status}{"\n"}{end}'
    echo "    HTTPRoutes (operator-managed, none until workloads launch):"
    kubectl get httproutes -n anyscale-operator
    echo "==> Done. Anyscale cloud $CLOUD_DEPLOYMENT_ID is ready."
  EOT
}

resource "local_file" "deploy_script" {
  filename        = "${path.module}/generated/deploy.sh"
  content         = local.deploy_script
  file_permission = "0755"
}

output "deploy_script_path" {
  description = "Path to a rendered shell script containing every post-terraform step in order (autoscaler, AWS LBC, optional S3 CSI addon, Envoy Gateway + manifests, PVC, Anyscale Operator, verify). Open it to copy-paste steps after substituting the BYO placeholders (<eks_cluster_name>, <anyscale_cloud_name>, <node_IAM_role_arn>)."
  value       = local_file.deploy_script.filename
}
