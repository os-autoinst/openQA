# Introduction

This README describes two ways to deploy the containers for the openQA web UI
and the workers.

The first one describes how to deploy an openQA environment using docker with
the Fedora images or images built locally.

The second one uses docker-compose to deploy a complete web UI with HA for the
API and the dashboard.

If a section or action is tagged as "Fedora", it should be applied only for a
Fedora deployment. If the tag "docker-compose" is used it will be used for the
docker-compose deployment.

# Get container images

You can either build the images locally or get the images from Docker hub.
Using the Docker hub can be easier for a first try.

## Download images from the Docker hub

### Fedora images (Fedora)

    docker pull fedoraqa/openqa_data
    docker pull fedoraqa/openqa_webui
    docker pull fedoraqa/openqa_worker

## Build images locally (mandatory in case of using docker-compose)

The Dockerfiles included in this project are for openSUSE:

    # Fedora and docker-compose
    docker build -t openqa_data ./openqa_data
    docker build -t openqa_webui ./webui
    docker build -t openqa_worker ./worker

    # docker-compose only
    docker build -f webui/Dockerfile-lb -t openqa_webui_lb ./webui

# Running openQA

Our intent was to create universal `webui` and `worker` containers and move
all data storage and configurations to a third container, called `openqa_data`.
`openqa_data` is so called
[Data Volume Container](http://docs.docker.com/userguide/dockervolumes/#creating-and-mounting-a-data-volume-container)
and is used as database as well as results and configuration storage. During
development and in production, you could update `webui` and `worker` images
but as long as `openqa_data` is intact, you do not lose any data.

To make development easier and to reduce final size of the `openqa_data`
container, this guide describes how to override `tests` and `factory`
directories with directories from your host system. This is not necessary but
recommended. This guide is written with this setup in mind.

It is also possible to use `tests` and `factory` from within the `openqa_data`
container (so you do not have any dependency on your host system) or to leave
out the `openqa_data` container altogether (so you have only `webui` and
`worker` containers and data is loaded and saved completely into your host
system). If this is what you prefer, refer to [Keeping all data in the Data
Volume Container] and [Keeping all data on the host system] sections
respectively.

## Update firewall rules (Fedora)

There is a
[bug in Fedora](https://bugzilla.redhat.com/show_bug.cgi?id=1244124)
with `docker-1.7.0-6` package that prevents containers to communicate with
each other. This bug prevents worker to connect to WebUI. As a workaround,
run:

    sudo iptables -A DOCKER --source 0.0.0.0/0 --destination 172.17.0.0/16 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    sudo iptables -A DOCKER --destination 0.0.0.0/0 --source 172.17.0.0/16 -j ACCEPT

on the host machine.

## Create directory structure

In case you want to have the big files (isos and disk images, test and
needles) outside of the docker volume container, you should create this file
structure from within the directory you are going to execute the container.

    mkdir -p data/factory/{iso,hdd} data/tests

It could be necessary to either run all containers in privileged mode, or set
selinux properly. If you are having problems with it, run this command:

    chcon -Rt svirt_sandbox_file_t data

## Run the Data & WebUI containers (Fedora)

    # Fedora
    docker run -d -h openqa_data --name openqa_data -v `pwd`/data/factory:/data/factory -v `pwd`/data/tests:/data/tests fedoraqa/openqa_data
    docker run -d -h openqa_webui --name openqa_webui --volumes-from openqa_data -p 80:80 -p 443:443 fedoraqa/openqa_webui

You can change the `-p` parameters if you do not want the openQA instance to
occupy ports 80 and 443, e.g. `-p 8080:80 -p 8043:443`, but this will cause
problems if you wish to set up workers on other hosts (see below). You do need
root privileges to bind ports 80 and 443 in this way.

It is now necessary to create and store the client keys for openQA. In the
next two steps, you will set an OpenID provider (if necessary), create the API
keys in the openQA's web interface, and store the configuration in the Data
Container.

## Run the Data & Web UI containers in HA mode (docker-compose)

    # To create the containers
    # in the directory openQA/docker/webui execute:
    docker-compose up -d

### Change the number web UI replicas (optional)

To set the number of replicas set the environment variable
`OPENQA_WEBUI_REPLICAS` to the desired number. If this is not set, then the
default value is 2.

```
export OPENQA_WEBUI_REPLICAS=3
```

Additionally you can edit the .env file to set the default value for this
variable.

### Change the exported port for the load balancer (optional)

By default the load balancer exposes the web UI on ports 9526, 80 and 443.

```
ports:
  - "80:9526"
```

### Enable the SSL access to the load balancer (optional)

Enable the SSL access in three steps:

1. To expose the SSL port uncomment this line in the docker-compose.yaml file
   in the service nginx.

```
- "443:443"
```

You can change the exported port if 443 is already used in your computer, for
instance:

```
- "10443:443"
```

2. Provide an SSL certificate.

```
- cert.crt:/etc/ssl/certs/openqa.crt
- cert.key:/etc/ssl/certs/openqa.key
```

3. Modify nginx.cfg to use this certificate. Uncomment the lines

```
ssl_certificate     /etc/ssl/certs/openqa.crt;
ssl_certificate_key /etc/ssl/certs/openqa.key;
```

### Change the OpenID provider

https://www.opensuse.org/openid/user/ is set as a default OpenID provider. To
change it, run:

    docker exec -it openqa_data /scripts/set_openid

and enter the Provider's URL.

### Set API keys

Go to https://localhost/api_keys, generate key and secret. Then run:

    # Fedora
    docker exec -it openqa_data /scripts/client-conf set -l KEY SECRET
    # Where KEY is your openQA instance key
    # and SECRET is your openQA instance secret

    # docker-compose
    docker exec -it openqa_data /scripts/client-conf set -l -t webui_nginx_1 KEY SECRET

## Run the Worker container

    # Fedora
    docker run -d -h openqa_worker_1 --name openqa_worker_1 --link openqa_webui:openqa_webui --volumes-from openqa_data --privileged fedoraqa/openqa_worker

    # docker-compose
    docker run -d -h openqa_worker_1 --name openqa_worker_1 --network webui_default --volumes-from openqa_data --privileged openqa_worker

Check whether the worker connected in the WebUI's administration interface.

To add more workers, increase the number that is used in hostname and
container name, so to add worker 2 use:

    # Fedora
    docker run -d -h openqa_worker_2 --name openqa_worker_2 --link openqa_webui:openqa_webui --volumes-from openqa_data --privileged fedoraqa/openqa_worker

    # docker-compose
    docker run -d -h openqa_worker_2 --name openqa_worker_2 --network webui_default --volumes-from openqa_data --privileged openqa_worker

## Run a pool of workers automatically (docker-compose)

To launch a pool of workers one could use the script `./launch_workers_pool.sh`.
It will launch the desired number of workers in individual containers using
consecutive numbers for the `--instance` parameter.

    ./launch_workers_pool.sh <number-of-workers>

## Enable services

Some systemd services are provided to start up the containers, so you do not
have to keep doing it manually. To install and enable them:

    sudo cp systemd/*.service /etc/systemd/system
    sudo systemctl daemon-reload
    sudo systemctl enable openqa-data.service
    sudo systemctl enable openqa-webui.service
    sudo systemctl enable openqa-worker@1.service

Of course, if you set up two workers, also do `sudo systemctl enable
openqa-worker@2.service`, and so on.

## Get tests, ISOs and create disks

You have to put your tests under `data/tests` directory and ISOs under
`data/factory/iso` directory.

### openSUSE

For testing openSUSE, follow
[this guide](https://github.com/os-autoinst/openQA/blob/master/docs/GettingStarted.asciidoc#testing-opensuse-or-fedora).

### Fedora

For testing Fedora, run:

    git clone https://bitbucket.org/rajcze/openqa_fedora data/tests/fedora
    wget https://dl.fedoraproject.org/pub/alt/stage/22_Beta_RC3/Server/x86_64/iso/Fedora-Server-netinst-x86_64-22_Beta.iso -O data/factory/iso/Fedora-Server-netinst-x86_64-22_Beta_RC3.iso

And set permissions, so any user can read/write the data:

    chmod -R 777 data

This step is unfortunately necessary because Docker
[can not mount a volume with specific user ownership](https://github.com/docker/docker/issues/7198)
in container, so ownership of mounted folders (uid and gid) is the same as on
your host system (presumably 1000:1000 which maps into nonexistent user in all
of the containers).

If you wish to keep the tests (for example) separate from the shared
directory, for any reason (we do, in our development scenario) refer to the
[Developing tests with Container setup] section at the end of this document.

Populate the openQA database:

    docker exec openqa_webui /var/lib/openqa/tests/fedora/templates

Create all necessary disk images:

    cd data/factory/hdd && createhdds.sh VERSION

where `VERSION` is the current stable Fedora version (its images will be
created for upgrade tests) and createhdds.sh is in `openqa_fedora_tools`
repository in `/tools` directory. Note that you have to have
`libguestfs-tools` and `libguestfs-xfs` installed.


# Running jobs

After performing the "setup" tasks above - do not forget about tests and ISOs
- you can schedule a test like this:

    docker exec openqa_webui /var/lib/openqa/script/client isos post ISO=Fedora-Server-netinst-x86_64-22_Beta_RC3.iso DISTRI=fedora VERSION=rawhide FLAVOR=generic_boot ARCH=x86_64 BUILD=22_Beta_RC3

# Other specific cases

## Adding workers on other hosts

You may want to add workers on other hosts, so you do not need one powerful
host to run the UI and all the workers.

Let's assume you are setting up a new 'worker host' and it can see the web UI
host system with the hostname `openqa_webui`.

You must somehow share the `data` directory from the web UI host to each host
on which you want to run workers. For instance, to use sshfs, on the new
worker host, run:

    sshfs -o context=unconfined_u:object_r:svirt_sandbox_file_t:s0 openqa_webui:/path/to/data /path/to/data

Of course, the worker host must have an ssh key the web UI host will accept.
You can add this mount to `/etc/fstab` to make it permanent.

Then check `openqa_fedora_tools` out on the worker host and run the data
container, as described above:

    docker run -d -h openqa_data --name openqa_data -v /path/to/data/factory:/data/factory -v /path/to/data/tests:/data/tests fedoraqa/openqa_data

and set up the API key with `docker exec -ti openqa_data /scripts/set_keys`.

Finally create a worker container, but omit the use of `--link`.  Ensure you
use a hostname which is different from all other worker instances on all other
hosts. The container name only has to be unique on this host, but it probably
makes sense to always match the hostname to the container name:

    docker run -h openqa_worker_3 --name openqa_worker_3 -d --volumes-from openqa_data --privileged fedoraqa/openqa_worker

If the container will not be able to resolve the `openqa_webui` hostname (this
depends on your network setup) you can use `--add-host` to add a line to
`/etc/hosts` when running the container:

    docker run -h openqa_worker_3 --name openqa_worker_3 -d --add-host="openqa_webui:10.0.0.1" --volumes-from openqa_data --privileged fedoraqa/openqa_worker

Worker instances always expect to find the server as `openqa_webui`; if this
will not work you must adjust the `/data/conf/client.conf` and
`/data/conf/workers.ini` files in the data container. You will also need to
adjust these files if you use non-standard ports (see above).

## Keeping all data in the Data Volume Container

If you decided to keep all the data in the Volume Container (`openqa_data`)
then instead of [Create directory structure] run:

    docker exec openqa_data mkdir -p data/factory/{iso,hdd} data/tests
    docker exec openqa_data chmod -R 777 data/factory/{iso,hdd} data/tests

In the [Run the Data & WebUI containers] section run the `openqa_data`
container like this instead:

    docker run -d -h openqa_data --name openqa_data fedoraqa/openqa_data

And finally, download the tests and ISOs directly into the container:

    docker exec openqa_data git clone https://bitbucket.org/rajcze/openqa_fedora /data/tests/fedora
    docker exec openqa_data wget https://dl.fedoraproject.org/pub/alt/stage/22_Beta_RC3/Server/x86_64/iso/Fedora-Server-netinst-x86_64-22_Beta.iso -O /data/factory/iso/Fedora-Server-netinst-x86_64-22_Beta_RC3

The rest of the steps should be the same.

## Keeping all data on the host system

If you want to keep all the data in the host system and you prefer to not use
a Volume Container then instead of [Create directory structure] run:

    cp -a openqa_data/data.template data
    chcon -Rt svirt_sandbox_file_t data

In the [Run the Data & WebUI containers] section do not run `openqa_data`
container and run the `webui` container like this instead:

    docker run -d -h openqa_webui -v `pwd`/data:/data --name openqa_webui -p 443:443 -p 80:80 fedoraqa/openqa_webui:4.1-3.12

Change OpenID provider in `data/conf/openqa.ini` under `provider` in
`[openid]` section and then put Key and Secret under both sections in
`data/conf/client.conf`.

In the [Run the Worker container] section, run worker as:

    docker run -h openqa_worker_1 --name openqa_worker_1 -d --link openqa_webui:openqa_webui -v `pwd`/data:/data --volumes-from openqa_webui --privileged fedoraqa/openqa_worker:4.1-3.12 1

Then continue with tests and ISOs downloading as before.

## Developing tests with Container setup

With this setup, the needles created from the WebUI will almost certainly have
different owner and group than your user account. As we have the tests in
git, and still want to retain the original owner and permission, even as we
update/create needles from openQA. To accomplish this, we are using BindFS.
An example entry in `/etc/fstab`:

    bindfs#/home/jskladan/src/openQA/openqa_fedora    /home/jskladan/src/openQA/openqa_fedora_tools/docker/data/tests/fedora    fuse    create-for-user=jskladan,create-for-group=jskladan,create-with-perms=664:a+X,perms=777    0    0

Mounts the `openqa_fedora` directory to the `.../tests/fedora directory`. All
files in the `tests/fedora` directory seem to have 777 permissions set, but
new files are created (in the underlying `openqa_fedora` directory) with
`jskladan:jskladan` user and group, and 664:a+X permissions.
