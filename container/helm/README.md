# Helm Chart for openQA inside Kubernetes

Prerequisites:

1. A Kubernetes cluster (for example [k3s](https://docs.k3s.io/)
2. Installed and configured Helm

For more information, please consult the [Helm
documentation](https://helm.sh/docs).

The chart consists of two separate sub-charts, _worker_ and _webui_, and
a parent chart, _openqa_.

## Installation

To install openQA, update helm dependencies and install the parent chart.

```
helm dependency update charts/openqa/
helm install openqa charts/openqa/
```

To uninstall and start over, use `helm uninstall openqa`.

## Configuration

It might be necessary to customize the charts by overriding some of the
variables inside _charts/values.yaml_ to suit your needs.

### Worker

The worker requires some basic configuration, as described in the
[documentation](http://open.qa/docs/#_run_openqa_workers). You can also set up
a [cache service](http://open.qa/docs/#asset-caching), which may improve
performance when handling assets, tests, and needles.
