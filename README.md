# Notes and scripts from KH - kubernetes the hard way
Link to [tutorial][df1]

Notes and scripts that split up the shell code that must be run locally to setup the GCP infrastructure vs. bootstraping the Kubernetes instances.
## Setup GCP
```
# Create an environment variable for the correct distribution
export CLOUD_SDK_REPO="cloud-sdk-$(lsb_release -c -s)"

# Add the Cloud SDK distribution URI as a package source
echo "deb http://packages.cloud.google.com/apt $CLOUD_SDK_REPO main" | sudo tee -a /etc/apt/sources.list.d/google-cloud-sdk.list

# Import the Google Cloud Platform public key
curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -

# Update the package list and install the Cloud SDK
sudo apt-get update && sudo apt-get install google-cloud-sdk

gcloud init
```
## Installing the Client Tools
In this lab you will install the command line utilities required to complete this tutorial: cfssl, cfssljson, and kubectl.
### Install CFSSL
The cfssl and cfssljson command line utilities will be used to provision a PKI Infrastructure and generate TLS certificates.
Download and install cfssl and cfssljson from the cfssl repository
### Install kubectl
The kubectl command line utility is used to interact with the Kubernetes API Server. Download and install kubectl from the official release binaries

## Setup Networking
```
gcloud compute networks create kubernetes-the-hard-way --subnet-mode custom
gcloud compute networks subnets create kubernetes \
  --network kubernetes-the-hard-way \
  --range 10.240.0.0/24
  
gcloud compute firewall-rules create kubernetes-the-hard-way-allow-internal \
  --allow tcp,udp,icmp \
  --network kubernetes-the-hard-way \
  --source-ranges 10.240.0.0/24,10.200.0.0/16
  
gcloud compute firewall-rules create kubernetes-the-hard-way-allow-external \
  --allow tcp:22,tcp:6443,icmp \
  --network kubernetes-the-hard-way \
  --source-ranges 0.0.0.0/0

gcloud compute addresses create kubernetes-the-hard-way \
  --region $(gcloud config get-value compute/region)

# Verify
gcloud compute addresses list --filter="name=('kubernetes-the-hard-way')"
```

# Create Certificates, Configurations, and Encryptions Key
From [CA and Generating TLS Certificates][tut4] to [Generating the Data Encryption Config and Key
][tut6]
Follow instructions, but skip ``*Client Certificates/Configuration Files``, this will be generated on the Nodes themselves.
Skip ``Distribute the Client and Server Certificates``, certs will be retreived by the bootstrap scripts.


# Copy Certs to GCP
Store certs in a Google storage bucket
```
# Create bucket
gsutil mb gs://[BUCKET_NAME]/
# Copy 
gsutil cp *.txt *.json *.csr *.yaml *.kubeconfig gs://[BUCKET_NAME]
```



# Create Instances 
```
####################
# Kubernetes MASTERS

for i in 0 1 2; do
  gcloud compute instances create controller-${i} \
    --async \
    --boot-disk-size 200GB \
    --can-ip-forward \
    --image-family ubuntu-1604-lts \
    --image-project ubuntu-os-cloud \
    --machine-type n1-standard-1 \
    --private-network-ip 10.240.0.1${i} \
    --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
    --subnet kubernetes \
    --tags kubernetes-the-hard-way,controller \
    --metadata-from-file startup-script=bootstrap/kube-gcp-controllers.sh
done

###################
# Kubernetes SLAVES
for i in 0 1 2; do
  gcloud compute instances create worker-${i} \
    --async \
    --boot-disk-size 200GB \
    --can-ip-forward \
    --image-family ubuntu-1604-lts \
    --image-project ubuntu-os-cloud \
    --machine-type n1-standard-1 \
    --metadata pod-cidr=10.200.${i}.0/24 \
    --private-network-ip 10.240.0.2${i} \
    --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
    --subnet kubernetes \
    --tags kubernetes-the-hard-way,worker \
    --metadata-from-file startup-script=bootstrap/kube-gcp-workers.sh
done

# verify
gcloud compute instances list
```
# Login to each controller instances, verify install
```
gcloud compute ssh controller-0
# or
gcloud compute ssh worker-0

## Verify
ETCDCTL_API=3 etcdctl member list
kubectl get componentstatuses

## Verify Nodes
kubectl get nodes
```

# The Kubernetes Frontend Load Balancer
[Kubernetes front end loadbalancer setup][tut8]
```
# Create the external load balancer network resources and forwarding rules, if they don't exist
KUBERNETES_PUBLIC_ADDRESS_NAME=$(gcloud compute addresses describe kubernetes-the-hard-way \
  --region $(gcloud config get-value compute/region) \
  --format 'value(name)')
gcloud compute target-pools create kubernetes-target-pool
gcloud compute forwarding-rules create kubernetes-forwarding-rule \
  --address ${KUBERNETES_PUBLIC_ADDRESS_NAME} \
  --ports 6443 \
  --region $(gcloud config get-value compute/region) \
  --target-pool kubernetes-target-pool

# Add controllers to target pools
gcloud compute target-pools add-instances kubernetes-target-pool \
  --instances controller-0,controller-1,controller-2
  
# Verify (when instances are running)
KUBERNETES_PUBLIC_ADDRESS=$(gcloud compute addresses describe kubernetes-the-hard-way \
  --region $(gcloud config get-value compute/region) \
  --format 'value(address)')
#   (get ca.pem from storage bucket if needed)
curl --cacert ca.pem https://${KUBERNETES_PUBLIC_ADDRESS}:6443/version
```

# Configuring kubectl for Remove Access
```
KUBERNETES_PUBLIC_ADDRESS=$(gcloud compute addresses describe kubernetes-the-hard-way \
  --region $(gcloud config get-value compute/region) \
  --format 'value(address)')
kubectl config set-cluster kubernetes-the-hard-way \
  --certificate-authority=ca.pem \
  --embed-certs=true \
  --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443
kubectl config set-credentials admin \
  --client-certificate=admin.pem \
  --client-key=admin-key.pem
kubectl config set-context kubernetes-the-hard-way \
  --cluster=kubernetes-the-hard-way \
  --user=admin

kubectl config use-context kubernetes-the-hard-way

# Verify 
kubectl get componentstatuses
```


   [df1]: <https://github.com/kelseyhightower/kubernetes-the-hard-way>
   [tut4]: <https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/04-certificate-authority.md#provisioning-a-ca-and-generating-tls-certificates>
   [tut6]:[https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/06-data-encryption-keys.md]
   [tut8]: <https://github.com/kelseyhightower/kubernetes-the-hard-way/blob/master/docs/08-bootstrapping-kubernetes-controllers.md#the-kubernetes-frontend-load-balancer>

