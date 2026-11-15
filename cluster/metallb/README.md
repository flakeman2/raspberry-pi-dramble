# MetalLB

MetalLB `0.16.2` in **layer 2** mode is the only load balancer. There is no
kube-vip; the `192.168.0.200` VIP from an earlier experiment does not exist.

```bash
kubectl apply -f metallb-v0.16.2.yaml
kubectl -n metallb-system rollout status deploy/controller --timeout=5m
kubectl -n metallb-system rollout status ds/speaker --timeout=5m
kubectl wait --for condition=established --timeout=60s \
  crd/ipaddresspools.metallb.io crd/l2advertisements.metallb.io
kubectl apply -f config.yaml
```

- Namespace: `metallb-system` (created by the manifest itself)
- `metallb-v0.16.2.yaml` is a local copy of upstream
  `config/manifests/metallb-native.yaml`: namespace, CRDs, validation webhook,
  controller Deployment and speaker DaemonSet. Vendoring it keeps the rebuild
  independent of a moving URL — it replaced `metallb-v0.11.0.yaml`, whose
  `policy/v1beta1` objects cannot be applied to Kubernetes 1.25 or newer.
- `config.yaml` is no longer a ConfigMap: since MetalLB 0.13 the address
  configuration is a pair of CRs, `IPAddressPool/default` and
  `L2Advertisement/default`, both `metallb.io/v1beta1`.
- Pool: `192.168.0.201-192.168.0.250`, advertised over L2
- Traefik is the only `LoadBalancer` Service. Its Service carries the
  `metallb.universe.tf/loadBalancerIPs: "192.168.0.201"` annotation (set in
  `../traefik/values.yaml`) so a reinstall cannot hand it a different address —
  public DNS points at `.201`.

Verify:

```bash
kubectl -n metallb-system get pods
kubectl -n metallb-system get ipaddresspool default \
  -o jsonpath='{.spec.addresses}'
kubectl -n metallb-system get l2advertisement
kubectl -n traefik get svc traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```
