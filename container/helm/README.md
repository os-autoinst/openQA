# Helm Chart for openQA inside Kubernetes

Prerequisites:

1. A Kubernetes cluster (for example [k3s](https://docs.k3s.io/) or [minikube](https://minikube.sigs.k8s.io/docs/))
2. Installed and configured Helm

For more information, please consult the [Helm
documentation](https://helm.sh/docs).

The chart consists of two separate sub-charts, _worker_ and _webui_, and
a parent chart, _openqa_.

## Installation

Make sure, first that a Kubernetes cluster is running
```bash
minikube start
minikube addons enable ingress
minikube status      
```

To install openQA, update helm dependencies and install the parent chart
from the `container/helm` directory:

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

By default the service type is `ClusterIP`, which requires an Ingress
controller for external access.

### Via Ingress (recommended)

The chart ships with Ingress enabled by default. The installation steps above
already enable the Ingress controller via `minikube addons enable ingress`.
Point the hostname configured in `values.yaml` (`baseUrl`) to your cluster.
For local development, add an entry to `/etc/hosts`:

```
127.0.0.1 openqa.host.org
```

Then access the UI at http://openqa.host.org.

### Via port-forward (quick testing)

```bash
kubectl port-forward svc/openqa 8080:80
```

Then access the UI at http://localhost:8080.

## Running a Test Job

The easiest way to run a job is to clone one from an existing openQA instance:

```bash
openqa-clone-job --from https://openqa.opensuse.org --host http://openqa.host.org <JOB_ID>
```

Pick a job ID from https://openqa.opensuse.org. This copies the job settings
and downloads the needed assets.

Alternatively, use `openqa-cli` to post a job directly:

```bash
openqa-cli api --host http://openqa.host.org -X POST jobs \
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
