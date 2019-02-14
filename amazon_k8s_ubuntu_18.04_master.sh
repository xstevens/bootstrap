# ------------------------------------------------------------------------------------------------------------------------
# We are explicitly not using a templating language to inject the values as to encourage the user to limit their
# use of templating logic in these files. By design all injected values should be able to be set at runtime,
# and the shell script real work. If you need conditional logic, write it in bash or make another shell script.
# ------------------------------------------------------------------------------------------------------------------------

# Specify the Kubernetes version to use.
KUBERNETES_VERSION="1.13.3"
KUBERNETES_CNI="0.6.0"

curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo apt-key add -
touch /etc/apt/sources.list.d/kubernetes.list
sh -c 'echo "deb http://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list'

# Has to be configured before installing kubelet, or kubelet has to be restarted to pick up changes
mkdir -p /etc/systemd/system/kubelet.service.d
touch /etc/systemd/system/kubelet.service.d/20-cloud-provider.conf
cat << EOF  > /etc/systemd/system/kubelet.service.d/20-cloud-provider.conf
[Service]
Environment="KUBELET_EXTRA_ARGS=--cloud-provider=aws"
EOF

chmod 0600 /etc/systemd/system/kubelet.service.d/20-cloud-provider.conf

apt-get update -y
apt-get install -y \
    socat \
    ebtables \
    docker.io \
    apt-transport-https \
    kubelet=${KUBERNETES_VERSION}-00 \
    kubeadm=${KUBERNETES_VERSION}-00 \
    kubernetes-cni=${KUBERNETES_CNI}-00 \
    cloud-utils \
    jq

systemctl enable docker
systemctl start docker

PUBLICIP=$(ec2metadata --public-ipv4 | cut -d " " -f 2)
PRIVATEIP=$(ec2metadata --local-ipv4 | cut -d " " -f 2)
TOKEN=$(cat /etc/kubicorn/cluster.json | jq -r '.clusterAPI.spec.providerConfig' | jq -r '.values.itemMap.INJECTEDTOKEN')
PORT=$(cat /etc/kubicorn/cluster.json | jq -r '.clusterAPI.spec.providerConfig' | jq -r '.values.itemMap.INJECTEDPORT | tonumber')

# Necessary for joining a cluster with AWS information
HOSTNAME=$(curl -sS http://169.254.169.254/latest/meta-data/local-hostname)

cat << EOF  > "/etc/kubicorn/kubeadm-config.yaml"
apiVersion: kubeadm.k8s.io/v1beta1
kind: InitConfiguration
bootstrapTokens:
- token: "${TOKEN}"
  description: "kubeadm bootstrap token"
  ttl: "24h"
nodeRegistration:
  name: ${HOSTNAME}
localAPIEndpoint:
  advertiseAddress: ${PRIVATEIP}
---
apiVersion: kubeadm.k8s.io/v1beta1
kind: ClusterConfiguration
kubernetesVersion: ${KUBERNETES_VERSION}
apiServer:
  extraArgs:
    authorization-mode: "Node,RBAC"
  certSANs:
    - ${PUBLICIP}
    - ${HOSTNAME}
    - ${PRIVATEIP}
networking:
  podSubnet: "192.168.0.0/16"
EOF

kubeadm reset -f
kubeadm init --config /etc/kubicorn/kubeadm-config.yaml

# install Calico
kubectl apply \
    -f https://docs.projectcalico.org/v3.3/getting-started/kubernetes/installation/hosted/rbac-kdd.yaml \
    --kubeconfig /etc/kubernetes/admin.conf
kubectl apply \
    -f https://docs.projectcalico.org/v3.3/getting-started/kubernetes/installation/hosted/kubernetes-datastore/calico-networking/1.7/calico.yaml \
    --kubeconfig /etc/kubernetes/admin.conf

# install AWS storage class
kubectl apply \
   -f  https://raw.githubusercontent.com/kubernetes/kubernetes/release-1.13/cluster/addons/storage-class/aws/default.yaml \
   --kubeconfig /etc/kubernetes/admin.conf

mkdir -p /home/ubuntu/.kube
cp /etc/kubernetes/admin.conf /home/ubuntu/.kube/config
chown -R ubuntu:ubuntu /home/ubuntu/.kube
