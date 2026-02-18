# Helm Chart for openQA inside Kubernetes

Prerequisites:

1. A Kubernetes cluster (for example [k3s](https://docs.k3s.io/) or [minikube](https://minikube.sigs.k8s.io/docs/))
2. Installed and configured Helm

For more information, please consult the [Helm
documentation](https://helm.sh/docs).

The chart consists of two separate sub-charts, _worker_ and _webui_, and
a parent chart, _openqa_.

## Installation

Make sure first that a Kubernetes cluster is running:

```bash
minikube start
minikube status
```

### Gateway API setup

The chart uses the [Kubernetes Gateway API](https://gateway-api.sigs.k8s.io/)
for external access. This has to be installed once before the provision of the
cluster. Install the Gateway API CRDs and
[Envoy Gateway](https://gateway.envoyproxy.io/) controller:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/<GW_VERSION>/standard-install.yaml --server-side
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  -n envoy-gateway-system --create-namespace --skip-crds
```

### Install the chart

Update helm dependencies (if needed) and install the parent chart from the
`container/helm` directory:

```bash
cd container/helm
helm dependency update openqa/
helm install openqa openqa/ --wait --timeout 5m
```
The dependency subcommand will build the manifests of the services, which can
be found under `openqa/charts/`.
The install will deploy the services in the cluster.

To uninstall and start over, use `helm uninstall openqa` and rerun
`helm dependency update openqa/`.

Check that everything is up and running:

```bash
helm status --show-resources openqa
```

## Accessing the Web UI

### Via Gateway API (recommended)

The chart creates a `Gateway` and `HTTPRoute` by default. For minikube, run
`minikube tunnel` in a separate terminal to assign an external IP to the
gateway's LoadBalancer service.

Find the gateway address:

```bash
kubectl get gateway
```

Add the gateway address to `/etc/hosts`, pointing to the hostname configured
in `values.yaml` (`baseUrl`):

```
<GATEWAY_ADDRESS> openqa.internal
```

Then access the UI at http://openqa.internal.

**Note:** In production, the cloud provider (AWS, GCP, etc.) provisions the
LoadBalancer automatically — no tunnel or manual IP configuration is needed.

### Via port-forward (quick testing)

No gateway setup needed. Forward the service port directly:

```bash
kubectl port-forward svc/openqa 8080:80
```

Then access the UI at http://localhost:8080.

## Running a Test Job

The easiest way to run a job is to clone one from an existing openQA instance:

```bash
openqa-clone-job --from https://openqa.opensuse.org --host http://openqa.internal <JOB_ID>
```

Pick a job ID from https://openqa.opensuse.org. This copies the job settings
and downloads the needed assets.

Alternatively, use `openqa-cli` to post a job directly:

```bash
openqa-cli api --host http://openqa.internal -X POST jobs \
  DISTRI=opensuse VERSION=Tumbleweed FLAVOR=DVD ARCH=x86_64 TEST=minimalx
```

## Configuration

It might be necessary to customize the charts by overriding some of the
variables inside `openqa/values.yaml` to suit your needs.

For testing, it is also useful to create a `my_values.yaml` and run:

```bash
helm install openqa openqa/ -f my_values.yaml
```

### Worker

The worker requires some basic configuration, as described in the
[documentation](http://open.qa/docs/#_run_openqa_workers).
