resource "libvirt_cloudinit_disk" "control_plane" {
  name      = "${var.prefix}_control-plane_cloud-init.iso"
  user_data = join("\n", ["#cloud-config", yamlencode(merge(local.user_data, { runcmd = local.control_plane_run_cmds }))])
}

resource "libvirt_cloudinit_disk" "node" {
  name      = "${var.prefix}_node_cloud-init.iso"
  user_data = join("\n", ["#cloud-config", yamlencode(merge(local.user_data, { runcmd = local.node_run_cmds }))])
}

locals {
  common_run_cmds = [
    "hostnamectl set-hostname $(uuidgen)",
    "modprobe br_netfilter",
    "modprobe overlay",
    "apt-mark hold kubelet kubeadm kubectl",
    "sysctl --system", # Reload settings from all system configuration files to take iptables configuration
    "systemctl restart containerd",
    "systemctl enable containerd",
  ]

  node_run_cmds = concat(local.common_run_cmds, [
    "until nc -zvw5 ${cidrhost(var.libvirt_cidr, var.control_plane_num)} 6443; do sleep 0.5; done",
    "kubeadm join ${cidrhost(var.libvirt_cidr, var.control_plane_num)}:6443 --token ${var.join_token} --discovery-token-unsafe-skip-ca-verification"
  ])
  control_plane_run_cmds = concat(local.common_run_cmds, [
    "snap install helm --classic",
    "helm repo add cilium https://helm.cilium.io/",
    "helm repo add argo https://argoproj.github.io/argo-helm",
    "helm repo update",
    "kubeadm init --token=${var.join_token} --skip-phases=addon/kube-proxy --cri-socket unix:///var/run/containerd/containerd.sock --v=5",
    "curl -Lsk -o /tmp/argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64",
    "install /tmp/argocd /usr/bin",
    "helm upgrade --wait --kubeconfig /etc/kubernetes/admin.conf --install --namespace kube-system cilium cilium/cilium -f /tmp/values-cilium.yaml --set k8sServiceHost=$(ip --json -4 a | jq -r '.[] | select(.ifname!=\"lo\") | .addr_info[0].local')",
    "kubectl --kubeconfig /etc/kubernetes/admin.conf create namespace argocd",
    "kubectl --kubeconfig /etc/kubernetes/admin.conf create namespace gateway",
    "kubectl --kubeconfig /etc/kubernetes/admin.conf create namespace cert-manager",
    "kubectl --kubeconfig /etc/kubernetes/admin.conf create namespace external-dns",
    "helm upgrade --wait --kubeconfig /etc/kubernetes/admin.conf --install argocd argo/argo-cd -f /tmp/values-argocd.yaml -n argocd",
    "kubectl --kubeconfig /etc/kubernetes/admin.conf create -f https://raw.githubusercontent.com/supertylerc/sre-portfolio/main/argo/applications/gateway-api.yaml",
    "kubectl --kubeconfig /etc/kubernetes/admin.conf create -f https://raw.githubusercontent.com/supertylerc/sre-portfolio/main/argo/applications/argocd.yaml",
    "kubectl --kubeconfig /etc/kubernetes/admin.conf create -f https://raw.githubusercontent.com/supertylerc/sre-portfolio/main/argo/applications/cilium.yaml",
    "kubectl --kubeconfig /etc/kubernetes/admin.conf create -f https://raw.githubusercontent.com/supertylerc/sre-portfolio/main/argo/applications/cert-manager.yaml",
    "kubectl --kubeconfig /etc/kubernetes/admin.conf create -f https://raw.githubusercontent.com/supertylerc/sre-portfolio/main/argo/applications/external-dns.yaml",
    "kubectl --kubeconfig /etc/kubernetes/admin.conf create secret generic cloudflare-api-token --from-literal=token=${var.cloudflare_token} --from-literal=email=${var.cloudflare_email} -n cert-manager",
    "kubectl --kubeconfig /etc/kubernetes/admin.conf create secret generic cloudflare-api-token --from-literal=token=${var.cloudflare_token} --from-literal=email=${var.cloudflare_email} -n external-dns",
    "mkdir -p /home/supertylerc/.kube",
    "cp -i /etc/kubernetes/admin.conf /home/supertylerc/.kube/config",
    "chown supertylerc:supertylerc /home/supertylerc/.kube",
    "chown supertylerc:supertylerc /home/supertylerc/.kube/config",
    "while kubectl --kubeconfig /etc/kubernetes/admin.conf get application -A | grep -v 'Synced.*Healthy' | grep -v NAME; do sleep 0.5; done",
    "while kubectl --kubeconfig /etc/kubernetes/admin.conf get -A pods -o custom-columns=NAMESPACE:metadata.namespace,POD:metadata.name,PodIP:status.podIP,READY-true:status.containerStatuses[*].ready | grep -v true; do sleep 0.5; done",
    "kubectl --kubeconfig /etc/kubernetes/admin.conf rollout restart deploy/cilium-operator -n kube-system",
    "kubectl --kubeconfig /etc/kubernetes/admin.conf rollout restart ds/cilium -n kube-system",
    "while kubectl --kubeconfig /etc/kubernetes/admin.conf get -A pods -o custom-columns=NAMESPACE:metadata.namespace,POD:metadata.name,PodIP:status.podIP,READY-true:status.containerStatuses[*].ready | grep -v true; do sleep 0.5; done"
  ])

  user_data = {
    users = [{
      name                = "supertylerc"
      hashed_passwd       = "$6$rounds=4096$nDzAXP.111c5arXO$58.b5gsevh.JHRNKzuw2BMd7P78VC19GYFOlzAOGIwOZUwWgxhaKq0HyWnq8GaKwfeDcF4cXIU.M4fyp7169U."
      lock_passwd         = false
      groups              = "users, admin"
      shell               = "/bin/bash"
      ssh_authorized_keys = [file("~/.ssh/id_ed25519.pub")]
    }]

    apt = {
      sources =  {
        "docker.list" = {
          source = "deb [arch=amd64] https://download.docker.com/linux/ubuntu $RELEASE stable"
	  keyid = "9DC858229FC7DD38854AE2D88D81803C0EBFCD88"
	}
	"kubernetes.list" = {
          source = "deb https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /"
          keyid = "DE15B14486CD377B9E876E1A234654DA9A296436"
	}
      }
    }
    package_update  = true
    package_upgrade = true
    packages = [
      "apt-transport-https",
      "ca-certificates",
      "curl",
      "gnupg",
      "lsb-release",
      "containerd.io",
      "cri-tools",
      "kubelet",
      "kubeadm",
      "kubectl",
    ]
    write_files = [
      {
        path = "/etc/modules-load.d/k8s.conf"
        content = join("\n", [
          "br_netfilter",
          "overlay"
        ])
      },
      {
        path = "/etc/sysctl.d/k8s.conf"
        content = join("\n", [
          "net.ipv4.ip_forward=1",
          "net.ipv6.conf.all.forwarding=1",
          "net.bridge.bridge-nf-call-ip6tables=1",
          "net.bridge.bridge-nf-call-iptables=1",
	  "net.ipv4.conf.all.proxy_arp=1",
	  "net.ipv4.conf.ens2.proxy_arp=1"
        ])
      },
      {
        path    = "/etc/containerd/config.toml"
        content = file("${path.module}/containerd.config.toml")
      },
      {
        path = "/etc/crictl.yaml"
        content = join("\n", [
          "runtime-endpoint: unix:///run/containerd/containerd.sock",
          "image-endpoint: unix:///run/containerd/containerd.sock",
          "timeout: 2",
          "debug: true # <- if you don't want to see debug info you can set this to false",
          "pull-image-on-create: false",
        ])
      },
      {
        path    = "/tmp/values-cilium.yaml"
        content = file("${path.module}/cilium.values.yaml")
      },
      {
        path    = "/tmp/values-argocd.yaml"
        content = file("${path.module}/argocd.values.yaml")
      },
    ]
    groups = ["docker"]
    power_state = {
      mode = "reboot"
    }
  }
}
