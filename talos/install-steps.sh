# steps to install my Talos cluster

talosctl gen config homelab https://192.168.0.61:6443 \
    --config-patch @install-disk.yaml \
    --config-patch @cni.yaml \
    --config-patch @schedule-cp.yaml \
    --config-patch @metrics-server.yaml \
    --config-patch @longhorn-extraMounts.yaml

talosctl apply-config --insecure --nodes 192.168.0.61 \
    --file controlplane.yaml \
    --config-patch @master-1.yaml


talosctl apply-config --insecure --nodes 192.168.0.62 \
    --file controlplane.yaml \
    --config-patch @master-2.yaml

talosctl apply-config --insecure --nodes 192.168.0.63 \
    --file controlplane.yaml \
    --config-patch @master-3.yaml

talosctl --talosconfig=./talosconfig config endpoints 192.168.0.61

talosctl bootstrap --nodes 192.168.0.61 --talosconfig=./talosconfig

# Generate kubeconfig file
talosctl kubeconfig --nodes 192.168.0.61 --talosconfig=./talosconfig

flux bootstrap github --personal --owner=Almothana12  --repository homelab --path=./k8s --branch=master