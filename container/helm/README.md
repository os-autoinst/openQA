### Helm Chart for openQA inside Kubernetes

Prerequisites:
1. A Kubernetes cluster (for example _k3s_ will do fine)
2. Installed and configured Helm

For more information please consult corresponding documentation for [k3s](https://rancher.com/docs/k3s/latest/en/) or [Helm](https://helm.sh/docs).

The charts consists of two separate sub-charts: _worker_ and _webui_. To install the chart simply execute `helm install openqa .` from this directory. To uninstall and start over, type `helm uninstall openqa`.

It might be necessary to customize the charts by overriding some of the variables inside _values.yaml_ to suit your needs.

#### Worker

The worker needs some basic settings as described in the [documentation](http://open.qa/docs/#_run_openqa_workers). It is possible to also setup a [cache service](http://open.qa/docs/#asset-caching) which might help with the assets/tests/needles.

An example configuration for the remote worker with cache services enabled, asset cache limited to 20Gi and custom `WORKER_CLASS`:

```
worker:
  openqa:
    host: my.openqa.instance
    key: 1234567890ABCDEF
    secret: 1234567890ABCDEF
  cacheService: true
  cacheLimit: 20
  workerClass: qemu_x86_64,kubernetes
```

#### WebUI

```
webui:
  baseUrl: my.openqa.instance
  useHttps: false
  key: 1234567890ABCDEF
  secret: 1234567890ABCDEF
  postgresql:
    enabled: true
    fullnameOverride: db
    postgresqlDatabase: openqa
    postgresqlUsername: openqa
    postgresqlPassword: openqa
```
