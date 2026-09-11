# steps to install my Talos cluster

talosctl gen config homelab https://192.168.0.61:6443 \
    --config-patch @install-disk.yaml \
    --config-patch @cni.yaml \
    --config-patch @schedule-cp.yaml \
    --config-patch @metrics-server.yaml \
    --config-patch @extraMounts.yaml \
    --config-patch @oidc.yaml \
    --config-patch @monitoring-cp.yaml \
    --config-patch @dual-stack.yaml \
    --config-patch @sysctls.yaml

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
kubectl create secret generic sops-age --namespace=flux-system --from-file=<PATH>

# GPU Workers
talosctl gen config homelab https://192.168.0.61:6443 \
    --with-secrets secrets.yaml \
    # workaround by Claude for the v1alpha1 format. use multi-doc config later
    --talos-version v1.11 \ 
    --output-types worker \
    --output worker-gpu.yaml \
    --config-patch @install-disk.yaml \
    --config-patch @cni.yaml \
    --config-patch @metrics-server.yaml \
    --config-patch @extraMounts.yaml \
    --config-patch @dual-stack.yaml \
    --config-patch @sysctls.yaml \
    --config-patch @gpu-install.yaml \
    --config-patch @gpu-worker-patch.yaml


talosctl apply-config --insecure --nodes 192.168.0.64 \
    --file worker-gpu.yaml \
    --config-patch @gpu-1.yaml

talosctl apply-config --insecure --nodes 192.168.0.65 \
    --file worker-gpu.yaml \
    --config-patch @gpu-2.yaml

# Taints and labels GPU workers. TODO: make this automatic in Talos config
kubectl taint nodes gpu-1 gpu-2 nvidia.com/gpu=present:NoSchedule 
kubectl label nodes gpu-1 gpu-2 node-role.kubernetes.io/gpu=