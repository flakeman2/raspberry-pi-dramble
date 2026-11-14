# MetalLB

MetalLB `0.11.0` in **layer 2** mode is the only load balancer. There is no
kube-vip; the `192.168.0.200` VIP from an earlier experiment does not exist.

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.11.0/manifests/namespace.yaml
kubectl apply -f metallb-v0.11.0.yaml
kubectl apply -f config.yaml
```

- Namespace: `metallb-system` (label `app=metallb`)
- Pool: `192.168.0.201-192.168.0.250`, protocol `layer2`
- Controller Deployment + `speaker` DaemonSet
- Traefik is the only `LoadBalancer` Service and receives `192.168.0.201`

`metallb-v0.11.0.yaml` is a local copy of the upstream
`manifests/metallb.yaml` so the rebuild does not depend on a moving URL.

Verify:

```bash
kubectl -n metallb-system get pods
kubectl -n metallb-system get cm config -o jsonpath='{.data.config}'
kubectl -n traefik get svc traefik \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```
