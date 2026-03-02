#!/bin/bash -x


wait_for_pods_running () {
  NS="$2"
  CMD="kubectl get pods --all-namespaces "
  if [ "$NS" != "all-namespaces" ]; then
    CMD="kubectl get pods -n $2 "
  fi
  KEYWORD="Running"
  if [ "$#" == "3" ]; then
    KEYWORD="${3}.*Running"
  fi

  CMD2="$CMD | grep \"$KEYWORD\" | wc -l"
  NUMPODS=$(eval "$CMD2")
  echo "waiting for $NUMPODS/$1 pods running in namespace [$NS] with keyword [$KEYWORD]"
  while [  $NUMPODS -lt $1 ]; do
    sleep 5
    NUMPODS=$(eval "$CMD2")
    echo "> waiting for $NUMPODS/$1 pods running in namespace [$NS] with keyword [$KEYWORD]"
  done 
}


start_ipv6_if () {
  IPv6IF="$1"
  if ifconfig -a $IPv6IF; then
    echo "" >> /etc/network/interfaces.d/50-cloud-init.cfg
    echo "allow-hotplug ${IPv6IF}" >> /etc/network/interfaces.d/50-cloud-init.cfg
    echo "iface ${IPv6IF} inet6 auto" >> /etc/network/interfaces.d/50-cloud-init.cfg
    ifconfig ${IPv6IF} up
  fi
}

echo "k8s_vm_install.sh"
set -x
export DEBIAN_FRONTEND=noninteractive
echo "$(hostname -I) $(hostname)" >> /etc/hosts
printenv

IPV6IF=""

rm -rf /opt/config
mkdir -p /opt/config
echo "" > /opt/config/docker_version.txt
# echo "1.16.0" > /opt/config/k8s_version.txt
# echo "0.7.5" > /opt/config/k8s_cni_version.txt
# echo "2.17.0" > /opt/config/helm_version.txt
echo "$(hostname -I)" > /opt/config/host_private_ip_addr.txt
echo "$(curl ifconfig.co)" > /opt/config/k8s_mst_floating_ip_addr.txt
echo "$(hostname -I)" > /opt/config/k8s_mst_private_ip_addr.txt
echo "__mtu__" > /opt/config/mtu.txt
echo "__cinder_volume_id__" > /opt/config/cinder_volume_id.txt
echo "$(hostname)" > /opt/config/stack_name.txt

ISAUX='false'
if [[ $(cat /opt/config/stack_name.txt) == *aux* ]]; then
  ISAUX='true'
fi

modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
# modprobe -- nf_conntrack_ipv4 # out of date. Will uncomment once this is done
# modprobe -- nf_conntrack_ipv6 # out of date.
# modprobe -- nf_conntrack_proto_sctp # out of date.
#just testing this for the newer version I will actually intergrate this once I am fully sure this is done
if [ ! -z "$IPV6IF" ]; then
  start_ipv6_if $IPV6IF
fi

SWAPFILES=$(grep swap /etc/fstab | sed '/^[ \t]*#/ d' | sed 's/[\t ]/ /g' | tr -s " " | cut -f1 -d' ')
if [ ! -z $SWAPFILES ]; then
  for SWAPFILE in $SWAPFILES
  do
    if [ ! -z $SWAPFILE ]; then
      echo "disabling swap file $SWAPFILE"
      if [[ $SWAPFILE == UUID* ]]; then
        UUID=$(echo $SWAPFILE | cut -f2 -d'=')
        swapoff -U $UUID
      else
        swapoff $SWAPFILE
      fi
      sed -i "\%$SWAPFILE%d" /etc/fstab
    fi
  done
fi

# Note make sure these vars are not used elsewhere
# DOCKERV=$(cat /opt/config/docker_version.txt)
# KUBEV=$(cat /opt/config/k8s_version.txt)
# KUBECNIV=$(cat /opt/config/k8s_cni_version.txt)

# KUBEVERSION="${KUBEV}-00"
# CNIVERSION="${KUBECNIV}-00"
# DOCKERVERSION="${DOCKERV}"

apt-get update && apt-get install -y apt-transport-https gnupg2 curl  ca-certificates gpg

UBUNTU_RELEASE=$(lsb_release -r | sed 's/^[a-zA-Z:\t ]\+//g')

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet
# if [[ ${UBUNTU_RELEASE} == 16.* ]]; then
#   echo "Installing on Ubuntu $UBUNTU_RELEASE (Xenial Xerus) host"
#   if [ ! -z "${DOCKERV}" ]; then
#     DOCKERVERSION="${DOCKERV}-0ubuntu1~16.04.5"
#   fi
# elif [[ ${UBUNTU_RELEASE} == 18.* ]]; then
#   echo "Installing on Ubuntu $UBUNTU_RELEASE (Bionic Beaver)"
#   if [ ! -z "${DOCKERV}" ]; then
#     DOCKERVERSION="${DOCKERV}-0ubuntu1~18.04.4"
#   fi
# elif [[ ${UBUNTU_RELEASE} == 20.* ]]; then
#   echo "Installing on Ubuntu $UBUNTU_RELEASE (Focal Fossa)"
#   if [ ! -z "${DOCKERV}" ]; then
#     DOCKERVERSION="${DOCKERV}-0ubuntu1~20.04.4"
#   elif DOCKERVERSION=$(sudo apt-cache policy docker.io | grep -o '20.\S*' | grep -m 1 'ubuntu'); then
#     echo Found docker.io version $DOCKERVERSION
#   elif DOCKERVERSION=$(sudo apt-cache policy docker.io | grep -o '19.\S*' | grep -m 1 'ubuntu'); then
#     echo Found docker.io version $DOCKERVERSION
#   else
#     echo Installing latest docker.io version
#   fi
# else
#   echo "Unsupported Ubuntu release ($UBUNTU_RELEASE) detected.  Exit."
#   exit
# fi



mkdir -p /etc/apt/apt.conf.d
echo "APT::Acquire::Retries \"3\";" > /etc/apt/apt.conf.d/80-retries

apt-get update 
apt install -y socat ebtables ethtool conntrack

# sudo dpkg -i cri-tools.deb

RES=$(apt-get install -y virt-what curl jq netcat make ipset moreutils 2>&1)
if [[ $RES == */var/lib/dpkg/lock* ]]; then
  echo "Fail to get dpkg lock.  Wait for any other package installation"
  echo "process to finish, then rerun this script"
  exit -1
fi

if ! echo $(virt-what) | grep "virtualbox"; then
  apt-get install -y linux-image-4.15.0-45-lowlatency
fi 

# APTOPTS="--allow-downgrades --allow-change-held-packages --allow-unauthenticated --ignore-hold "

# for PKG in kubeadm docker.io; do
#   INSTALLED_VERSION=$(dpkg --list |grep ${PKG} |tr -s " " |cut -f3 -d ' ')
#   if [ ! -z ${INSTALLED_VERSION} ]; then
#     if [ "${PKG}" == "kubeadm" ]; then
#       kubeadm reset -f
#       rm -rf ~/.kube
#       apt-get -y $APTOPTS remove kubeadm kubelet kubectl kubernetes-cni
#     else
#       apt-get -y $APTOPTS remove "${PKG}"
#     fi
#   fi
# done
# apt-get -y autoremove

# if [ -z ${DOCKERVERSION} ]; then
#   apt-get install -y $APTOPTS docker.io
# else
#   apt-get install -y $APTOPTS docker.io=${DOCKERVERSION}
# fi
apt remove $(dpkg --get-selections docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc | cut -f1)
# Add Docker's official GPG key:
apt update
apt install ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update

cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF
cat /etc/containerd/config.toml #NOTE: Remember to remove this. This is just me debuging
containerd config default > /etc/containerd/config.toml

mkdir -p /etc/systemd/system/docker.service.d
systemctl enable docker.service
systemctl daemon-reload
systemctl restart docker
systemctl restart containerd



# if [ -z ${KUBEVERSION} ]; then
# 	sudo dpkg -i kubernetes-cni_0.7.5-00_amd64_b38a324bb34f923d353203adf0e048f3b911f49fa32f1d82051a71ecfe2cd184.deb
# 	sudo dpkg -i kubelet_1.16.0-00_amd64_e919939f5dad4bc7b0047fe2cf2870ab1946e87f948ab7f75bc1d63305436664_1.deb
# 	sudo dpkg -i kubectl_1.16.0-00_amd64_679986772c12ed40781ae02317f3211f8615427c033194618ba2fdecc1cee43f.deb
# 	sudo dpkg -i kubeadm_1.16.0-00_amd64_b0fa26a7ac8cd90e9c3e388282828f320766264acc307b5bf45ffa79b5abed0c.deb
# 	sudo apt-get install -f
# else
# 	sudo dpkg -i kubernetes-cni_0.7.5-00_amd64_b38a324bb34f923d353203adf0e048f3b911f49fa32f1d82051a71ecfe2cd184.deb
# 	sudo dpkg -i kubelet_1.16.0-00_amd64_e919939f5dad4bc7b0047fe2cf2870ab1946e87f948ab7f75bc1d63305436664_1.deb
# 	sudo dpkg -i kubectl_1.16.0-00_amd64_679986772c12ed40781ae02317f3211f8615427c033194618ba2fdecc1cee43f.deb
# 	sudo dpkg -i kubeadm_1.16.0-00_amd64_b0fa26a7ac8cd90e9c3e388282828f320766264acc307b5bf45ffa79b5abed0c.deb
# 	sudo apt-get install -f
# fi



kubeadm config images pull


# NODETYPE="master"
# if [ "$NODETYPE" == "master" ]; then

#   if [[ ${KUBEV} == 1.13.* ]]; then
#     cat <<EOF >/root/config.yaml
# apiVersion: kubeadm.k8s.io/v1alpha3
# kubernetesVersion: v${KUBEV}
# kind: ClusterConfiguration
# apiServerExtraArgs:
#   feature-gates: SCTPSupport=true
# networking:
#   dnsDomain: cluster.local
#   podSubnet: 10.244.0.0/16
#   serviceSubnet: 10.96.0.0/12
# ---
# apiVersion: kubeproxy.config.k8s.io/v1alpha1
# kind: KubeProxyConfiguration
# mode: ipvs
# EOF

#   elif [[ ${KUBEV} == 1.14.* ]]; then
#     cat <<EOF >/root/config.yaml
# apiVersion: kubeadm.k8s.io/v1beta1
# kubernetesVersion: v${KUBEV}
# kind: ClusterConfiguration
# apiServerExtraArgs:
#   feature-gates: SCTPSupport=true
# networking:
#   dnsDomain: cluster.local
#   podSubnet: 10.244.0.0/16
#   serviceSubnet: 10.96.0.0/12
# ---
# apiVersion: kubeproxy.config.k8s.io/v1alpha1
# kind: KubeProxyConfiguration
# mode: ipvs
# EOF
#   elif [[ ${KUBEV} == 1.15.* ]] || [[ ${KUBEV} == 1.16.* ]] || [[ ${KUBEV} == 1.18.* ]]; then
#     cat <<EOF >/root/config.yaml
# apiVersion: kubeadm.k8s.io/v1beta2
# kubernetesVersion: v${KUBEV}
# kind: ClusterConfiguration
# apiServer:
#   extraArgs:
#     feature-gates: SCTPSupport=true
# networking:
#   dnsDomain: cluster.local
#   podSubnet: 10.244.0.0/16
#   serviceSubnet: 10.96.0.0/12
# ---
# apiVersion: kubeproxy.config.k8s.io/v1alpha1
# kind: KubeProxyConfiguration
# mode: ipvs
# EOF
#   else
#     echo "Unsupported Kubernetes version requested.  Bail."
#     exit
#   fi

#   cat <<EOF > /root/rbac-config.yaml
# apiVersion: v1
# kind: ServiceAccount
# metadata:
#   name: tiller
#   namespace: kube-system
# ---
# apiVersion: rbac.authorization.k8s.io/v1
# kind: ClusterRoleBinding
# metadata:
#   name: tiller
# roleRef:
#   apiGroup: rbac.authorization.k8s.io
#   kind: ClusterRole
#   name: cluster-admin
# subjects:
#   - kind: ServiceAccount
#     name: tiller
#     namespace: kube-system
# EOF

  cat <<EOF >/root/config.yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
networking:
  dnsDomain: cluster.local
  podSubnet: 10.244.0.0/16
  serviceSubnet: 10.96.0.0/12
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
mode: ipvs
EOF
  kubeadm init --config /root/config.yaml

  cd /root
  rm -rf .kube
  mkdir -p .kube
  cp -i /etc/kubernetes/admin.conf /root/.kube/config
  chown root:root /root/.kube/config
  export KUBECONFIG=/root/.kube/config
  echo "KUBECONFIG=${KUBECONFIG}" >> /etc/environment

  kubectl get pods --all-namespaces

  ARCH=$(uname -m)
  case $ARCH in
    armv7*) ARCH="arm";;
    aarch64) ARCH="arm64";;
    x86_64) ARCH="amd64";;
  esac
  mkdir -p /opt/cni/bin
  curl -O -L https://github.com/containernetworking/plugins/releases/download/v1.7.1/cni-plugins-linux-$ARCH-v1.7.1.tgz
  tar -C /opt/cni/bin -xzf cni-plugins-linux-$ARCH-v1.7.1.tgz
  kubectl apply -f "https://raw.githubusercontent.com/flannel-io/flannel/refs/heads/master/Documentation/kube-flannel.yml"

  wait_for_pods_running 8 A

  # kubectl taint nodes --all node-role.kubernetes.io/master-#been replaced with control panel
  kubectl taint nodes --all node-role.kubernetes.io/control-plane- 
  apt-get install curl gpg apt-transport-https --yes
  curl -fsSL https://packages.buildkite.com/helm-linux/helm-debian/gpgkey | gpg --dearmor | sudo tee /usr/share/keyrings/helm.gpg > /dev/null
  echo "deb [signed-by=/usr/share/keyrings/helm.gpg] https://packages.buildkite.com/helm-linux/helm-debian/any/ any main" | sudo tee /etc/apt/sources.list.d/helm-stable-debian.list
  apt-get update
  apt-get install helm
  # HELMV=$(cat /opt/config/helm_version.txt)
  # HELMVERSION=${HELMV}
  # if [ ! -e helm-v${HELMVERSION}-linux-amd64.tar.gz ]; then
  #   wget https://get.helm.sh/helm-v${HELMVERSION}-linux-amd64.tar.gz
  # fi
  # cd /root && rm -rf Helm && mkdir Helm && cd Helm
  # tar -xvf ../helm-v${HELMVERSION}-linux-amd64.tar.gz
  # mv linux-amd64/helm /usr/local/bin/helm

  # cd /root
  # if [[ ${HELMVERSION} == 2.* ]]; then
  #    kubectl create -f rbac-config.yaml
  # fi

  # rm -rf /root/.helm
  # if [[ ${KUBEV} == 1.16.* ]]; then
  #   if [[ ${HELMVERSION} == 2.* ]]; then
  #      helm init --service-account tiller --override spec.selector.matchLabels.'name'='tiller',spec.selector.matchLabels.'app'='helm' --output yaml > /tmp/helm-init.yaml
  #      sed 's@apiVersion: extensions/v1beta1@apiVersion: apps/v1@' /tmp/helm-init.yaml > /tmp/helm-init-patched.yaml
  #      kubectl apply -f /tmp/helm-init-patched.yaml
  #   fi
  # else
  #   if [[ ${HELMVERSION} == 2.* ]]; then
  #      helm init --service-account tiller
  #   fi
  # fi
  # if [[ ${HELMVERSION} == 2.* ]]; then
  #    helm init -c
  #    export HELM_HOME="$(pwd)/.helm"
  #    echo "HELM_HOME=${HELM_HOME}" >> /etc/environment
  # fi

  while ! helm version; do
    echo "Waiting for Helm to be ready"
    sleep 15
  done

  mkdir -p /root/.cache/helm/repository/local
  mkdir -p /root/.cache/helm/repository/local/charts
  (cd /root/.cache/helm/repository/local && helm repo index .)

  echo "Preparing a master node (lowser ID) for using local FS for PV"
  PV_NODE_NAME=$(kubectl get nodes |grep control-plane | cut -f1 -d' ' | sort | head -1)
  kubectl label --overwrite nodes $PV_NODE_NAME local-storage=enable
  if [ "$PV_NODE_NAME" == "$(hostname)" ]; then
    mkdir -p /opt/data/dashboard-data
  fi

  echo "Done with master node setup"


if [[ ! -z "" && ! -z "" ]]; then 
  echo " " >> /etc/hosts
fi
if [[ ! -z "" && ! -z "" ]]; then 
  echo " " >> /etc/hosts
fi
if [[ ! -z "" && ! -z "helm.ricinfra.local" ]]; then 
  echo " helm.ricinfra.local" >> /etc/hosts
fi

if [[ "1" -gt "100" ]]; then
  cat <<EOF >/etc/ca-certificates/update.d/helm.crt

EOF
fi

if [[ "1" -gt "100" ]]; then
  mkdir -p /etc/docker/certs.d/:
  cat <<EOF >/etc/docker/ca.crt

EOF
  cp /etc/docker/ca.crt /etc/docker/certs.d/:/ca.crt

  service docker restart
  systemctl enable docker.service
  docker login -u  -p  :
  docker pull :/whoami:0.0.1
fi

