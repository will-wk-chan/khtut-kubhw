#!/bin/bash

# README
# Provisioning a Kubernetes Worker Node
# https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/09-bootstrapping-kubernetes-workers.md
# EDIT (below)
GS_BUCKET=dev-bucket-ks
# EDIT (above)

### (Required Certs)
gsutil cp gs://${GS_BUCKET}/ca.pem /tmp/
gsutil cp gs://${GS_BUCKET}/ca-key.pem /tmp/
gsutil cp gs://${GS_BUCKET}/ca-config.json /tmp/
gsutil cp gs://${GS_BUCKET}/kube-proxy.kubeconfig /tmp/

# install cfssl to generate certs later on
wget -q --show-progress --https-only --timestamping \
  https://pkg.cfssl.org/R1.2/cfssl_linux-amd64 \
  https://pkg.cfssl.org/R1.2/cfssljson_linux-amd64

chmod +x cfssl_linux-amd64 cfssljson_linux-amd64
sudo mv cfssl_linux-amd64 /usr/local/bin/cfssl
sudo mv cfssljson_linux-amd64 /usr/local/bin/cfssljson

# Download and Install Worker Binaries
sudo apt-get -y install socat

cd /root

wget -q --show-progress --https-only --timestamping \
  https://github.com/containernetworking/plugins/releases/download/v0.6.0/cni-plugins-amd64-v0.6.0.tgz \
  https://github.com/containerd/cri-containerd/releases/download/v1.0.0-beta.1/cri-containerd-1.0.0-beta.1.linux-amd64.tar.gz \
  https://storage.googleapis.com/kubernetes-release/release/v1.9.0/bin/linux/amd64/kubectl \
  https://storage.googleapis.com/kubernetes-release/release/v1.9.0/bin/linux/amd64/kube-proxy \
  https://storage.googleapis.com/kubernetes-release/release/v1.9.0/bin/linux/amd64/kubelet

sudo mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes \
  /var/run/kubernetes

sudo tar -xvf cni-plugins-amd64-v0.6.0.tgz -C /opt/cni/bin/
sudo tar -xvf cri-containerd-1.0.0-beta.1.linux-amd64.tar.gz -C /
chmod +x kubectl kube-proxy kubelet
sudo mv kubectl kube-proxy kubelet /usr/local/bin/

# Configure CNI Networking
# Retrieve the Pod CIDR range for the current compute instance:
POD_CIDR=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/pod-cidr)

# Create the bridge network configuration file:
cat > 10-bridge.conf <<EOF
{
    "cniVersion": "0.3.1",
    "name": "bridge",
    "type": "bridge",
    "bridge": "cnio0",
    "isGateway": true,
    "ipMasq": true,
    "ipam": {
        "type": "host-local",
        "ranges": [
          [{"subnet": "${POD_CIDR}"}]
        ],
        "routes": [{"dst": "0.0.0.0/0"}]
    }
}
EOF

# Create the loopback network configuration file:
cat > 99-loopback.conf <<EOF
{
    "cniVersion": "0.3.1",
    "type": "loopback"
}
EOF

# Move the network configuration files to the CNI configuration directory:
sudo mv 10-bridge.conf 99-loopback.conf /etc/cni/net.d/

# Configure the Kubelet
#   requires certs
LOCAL_HOSTNAME=$(hostname -s)

cat > ${LOCAL_HOSTNAME}-csr.json <<EOF
{
  "CN": "system:node:${LOCAL_HOSTNAME}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:nodes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

EXTERNAL_IP=$(curl -H "Metadata-Flavor: Google" http://metadata/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

INTERNAL_IP=$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)


# generate node certs

cfssl gencert \
  -ca=/tmp/ca.pem \
  -ca-key=/tmp/ca-key.pem \
  -config=/tmp/ca-config.json \
  -hostname=${LOCAL_HOSTNAME},${EXTERNAL_IP},${INTERNAL_IP} \
  -profile=kubernetes \
  ${LOCAL_HOSTNAME}-csr.json | cfssljson -bare ${LOCAL_HOSTNAME}

# Generate kubeconfig file
ZONE_REGION=$(curl -H "Metadata-Flavor: Google" http://metadata/computeMetadata/v1/instance/zone | grep -oE '[^/]+$' | grep -oE '\w+\-\w+')
echo "Zone Region: $ZONE_REGION}"
KUBERNETES_PUBLIC_ADDRESS=$(gcloud compute addresses describe kubernetes-the-hard-way \
  --region ${ZONE_REGION} \
  --format 'value(address)')
kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=/tmp/ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
    --kubeconfig=${LOCAL_HOSTNAME}.kubeconfig

kubectl config set-credentials system:node:${LOCAL_HOSTNAME} \
    --client-certificate=${LOCAL_HOSTNAME}.pem \
    --client-key=${LOCAL_HOSTNAME}-key.pem \
    --embed-certs=true \
    --kubeconfig=${LOCAL_HOSTNAME}.kubeconfig

kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:node:${LOCAL_HOSTNAME} \
    --kubeconfig=${LOCAL_HOSTNAME}.kubeconfig

# set as default context
kubectl config use-context default --kubeconfig=${LOCAL_HOSTNAME}.kubeconfig

sudo cp ${LOCAL_HOSTNAME}-key.pem ${LOCAL_HOSTNAME}.pem /var/lib/kubelet/
sudo cp ${LOCAL_HOSTNAME}.kubeconfig /var/lib/kubelet/kubeconfig
sudo cp /tmp/ca.pem /var/lib/kubernetes/

# Create the kubelet.service systemd unit file:

cat > kubelet.service <<EOF
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=cri-containerd.service
Requires=cri-containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --allow-privileged=true \\
  --anonymous-auth=false \\
  --authorization-mode=Webhook \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --cloud-provider= \\
  --cluster-dns=10.32.0.10 \\
  --cluster-domain=cluster.local \\
  --container-runtime=remote \\
  --container-runtime-endpoint=unix:///var/run/cri-containerd.sock \\
  --image-pull-progress-deadline=2m \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --network-plugin=cni \\
  --pod-cidr=${POD_CIDR} \\
  --register-node=true \\
  --runtime-request-timeout=15m \\
  --tls-cert-file=/var/lib/kubelet/${LOCAL_HOSTNAME}.pem \\
  --tls-private-key-file=/var/lib/kubelet/${LOCAL_HOSTNAME}-key.pem \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Configure the Kubernetes Proxy
sudo mv /tmp/kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig

cat > kube-proxy.service <<EOF
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --cluster-cidr=10.200.0.0/16 \\
  --kubeconfig=/var/lib/kube-proxy/kubeconfig \\
  --proxy-mode=iptables \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# start worker service
sudo mv kubelet.service kube-proxy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable containerd cri-containerd kubelet kube-proxy
sudo systemctl start containerd cri-containerd kubelet kube-proxy


# Verify, login to controller node
# gcloud compute ssh controller-0
# kubectl get nodes