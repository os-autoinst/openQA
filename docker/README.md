# Get docker images

You can either build the images locally, or get the images from the Docker hub. We recommend using the Docker hub option.

## Download images from the Docker hub

## Build images locally

The Dockerfiles included in this project are for openSUSE:

    docker build -t openqa_data ./openqa_data
    docker build -t openqa_webui ./webui
    docker build -t openqa_worker ./worker

# Running OpenQA

Our intent was to create universal `webui` and `worker` containers and move all data storage and configurations to third container,
called `openqa_data`. `openqa_data` is so called [Data Volume Container](http://docs.docker.com/userguide/dockervolumes/#creating-and-mounting-a-data-volume-container)
and is used as database, results and configuration storage. During development and in production, you could update `webui` and `worker` images
but as long as `openqa_data` is intact, you don't lochanged in the docker-compose.yaml for the service haproxy. For instance tose any data.

To make development easier and to reduce final size of `openqa_data` container, this guide describes how to override `tests` and `factory` directories
with directories from your host system. It's not necessary, but it's recommended and this guide is written with this setup in mind.

It's also possible to use `tests` and `factory` from within the `openqa_data` container (so you don't have any dependency on your host system) or
to ditch `openqa_data` container altogether (so you have only `webui` and `worker` containers and data is loaded and saved completely into your host
system). If this is what you want, refer to [Keeping all data in the Data Volume Container] and [Keeping all data on the host system] sections respectively.

## Create directory structure

In case you want to have the big files (isos and disk images, test and needles) outside of the docker volume container,
you should create this file structrure from within the directory you are going to execute the container.

    mkdir -p workdir/data/factory/{iso,hdd} data/tests

It could be necessary to either run all containers in privileged mode, or set selinux properly. If you are having problems with it, run this command:

    chcon -Rt svirt_sandbox_file_t data

## Run the Data & Web UI containers in HA mode with docker-compose

    # To create the containers
    # in the directory openQA/docker/webui execute:
    docker-compose up -d

### Change the number web UI replicas (optional)

To set the number of replicas set the environment variable OPENQA_WEBUI_REPLICAS
to the desired number. If this is not set, then the default value is 2.

```
export OPENQA_WEBUI_REPLICAS=3
```

Additionally you can edit the .env file to set the default value for this variable.

### Change the exported port for the load balancer (optional)

By default the load balancer exposes the web UI on port 9526. That can be
changed in `docker-compose.yaml` for the service haproxy. For instance, to
expose on port 80, change the first number in the tuple of ports for this service.

```
ports:
  - "80:9526"
```

### Enable the SSL access to the load balancer (optional)

Enable the SSL access in three steps:

1. To expose the SSL port uncomment this line in the docker-compose.yaml file in the service haproxy.

```
- "443:443"
```

You can change the exported port if 443 is already used in your computer, for instance:

```
- "10443:443"
```

2. Provide an SSL certificate.

```
- cert.pem:/etc/ssl/certs/cert.pem
```

3. Modify haproxy.cfg to use this certificate. Modify the haproxy.cfg and uncomment the line
```
bind *:443 ssl crt /etc/ssl/certs/cert.pem
    ```

### Change the OpenID provider (optional)

https://www.opensuse.org/openid/user/ is set as a default OpenID provider. To change it, run:

    docker exec -it openqa_data /scripts/set_openid

and enter the Provider's URL.

### Set API keys

Go to https://localhost/api_keys, generate key and secret. Then run:

    docker exec -it openqa_data /scripts/client-conf set -l KEY SECRET
    # Where KEY is your openQA instance key
    # and SECRET is your openQA instance secret


## Run the Worker container

    # Fedora
    docker run -d -h openqa_worker_1 --name openqa_worker_1 --link openqa_webui:openqa_webui --volumes-from openqa_data --privileged fedoraqa/openqa_worker

Check whether the worker connected in the WebUI's administration interface.

To add more workers, increase number that is used in hostname and container name, so to add worker 2 use:

    # Fedora
    docker run -d -h openqa_worker_2 --name openqa_worker_2 --link openqa_webui:openqa_webui --volumes-from openqa_data --privileged fedoraqa/openqa_worker

## Enable services

Some systemd services are provided to start up the containers, so you don't have to keep doing it manually. To install and enable them:

    sudo cp systemd/*.service /etc/systemd/system
    sudo systemctl daemon-reload
    sudo systemctl enable openqa-data.service
    sudo systemctl enable openqa-webui.service
    sudo systemctl enable openqa-worker@1.service

Of course, if you set up two workers, also do `sudo systemctl enable openqa-worker@2.service`, and so on.

## Get tests, ISOs and create disks

You have to put your tests under `data/tests` directory and ISOs under `data/factory/iso` directory.

### openSUSE

For testing openSUSE, follow [this guide](https://github.com/os-autoinst/openQA/blob/master/docs/GettingStarted.asciidoc#testing-opensuse-or-fedora).

### Fedora

For testing Fedora, run:

    git clone https://bitbucket.org/rajcze/openqa_fedora data/tests/fedora
    wget https://dl.fedoraproject.org/pub/alt/stage/22_Beta_RC3/Server/x86_64/iso/Fedora-Server-netinst-x86_64-22_Beta.iso -O data/factory/iso/Fedora-Server-netinst-x86_64-22_Beta_RC3.iso

And set permissions, so any user can read/write the data:

    chmod -R 777 data

This step is unfortunately necessary because Docker [can't mount volume with specific user ownership](https://github.com/docker/docker/issues/7198) in container, so ownership of mounted folders (uid and gid) is the same as on your host system (presumably 1000:1000 which maps into nonexistent user in all of the containers).

If you wish to keep the tests (for example) separate from the shared directory, for any reason (we do, in our development scenario) refer to the [Developing tests with Container setup] section at the end of this document.

Populate the OpenQA's database:

    docker exec openqa_webui /var/lib/openqa/tests/fedora/templates

Create all necessary disk images:

    cd data/factory/hdd && createhdds.sh VERSION

where `VERSION` is current stable Fedora version (its images will be created for upgrade tests) and createhdds.sh is in `openqa_fedora_tools` repository in `/tools` directory. Note that you have to have `libguestfs-tools` and `libguestfs-xfs` installed.


# Running jobs

After performing the "setup" tasks above - do not forget about tests and ISOs - you can schedule a test like this:

    docker exec openqa_webui /var/lib/openqa/script/client isos post ISO=Fedora-Server-netinst-x86_64-22_Beta_RC3.iso DISTRI=fedora VERSION=rawhide FLAVOR=generic_boot ARCH=x86_64 BUILD=22_Beta_RC3

# Other specific cases

## Adding workers on other hosts

You may want to add workers on other hosts, so you don't need one powerful host to run the UI and all the workers.

Let's assume you're setting up a new 'worker host', and it can see the web UI host system with the hostname `openqa_webui`.

You must somehow share the `data` directory from the web UI host to each host on which you want to run workers. For instance, to use sshfs, on the new worker host, run:

    sshfs -o context=unconfined_u:object_r:svirt_sandbox_file_t:s0 openqa_webui:/path/to/data /path/to/data

Of course, the worker host must have an ssh key the web UI host will accept. You can add this mount to `/etc/fstab` to make it permanent.

Then check `openqa_fedora_tools` out on the worker host and run the data container, as described above:

    docker run -d -h openqa_data --name openqa_data -v /path/to/data/factory:/data/factory -v /path/to/data/tests:/data/tests fedoraqa/openqa_data

and set up the API key with `docker exec -ti openqa_data /scripts/set_keys`.

Finally create a worker container, but omit the use of `--link`.  Ensure you use a hostname which is different from all other worker instances on all other hosts. The container name only has to be unique on this host, but it probably makes sense to always match the hostname to the container name:

    docker run -h openqa_worker_3 --name openqa_worker_3 -d --volumes-from openqa_data --privileged fedoraqa/openqa_worker

If the container will not be able to resolve the `openqa_webui` hostname (this depends on your network setup) you can use `--add-host` to add a line to `/etc/hosts` when running the container:

    docker run -h openqa_worker_3 --name openqa_worker_3 -d --add-host="openqa_webui:10.0.0.1" --volumes-from openqa_data --privileged fedoraqa/openqa_worker

Worker instances always expect to find the server as `openqa_webui`; if this will not work you must adjust the `/data/conf/client.conf` and `/data/conf/workers.ini` files in the data container. You will also need to adjust these files if you use non-standard ports (see above).

## Keeping all data in the Data Volume Container

If you decided to keep all the data in the Volume Container (`openqa_data`) then instead of [Create directory structure] run:

    docker exec openqa_data mkdir -p data/factory/{iso,hdd} data/tests
    docker exec openqa_data chmod -R 777 data/factory/{iso,hdd} data/tests

In the [Run the Data & WebUI containers] section run the `openqa_data` container like this instead:

    docker run -d -h openqa_data --name openqa_data fedoraqa/openqa_data

And finally, download the tests and ISOs directly into the container:

    docker exec openqa_data git clone https://bitbucket.org/rajcze/openqa_fedora /data/tests/fedora
    docker exec openqa_data wget https://dl.fedoraproject.org/pub/alt/stage/22_Beta_RC3/Server/x86_64/iso/Fedora-Server-netinst-x86_64-22_Beta.iso -O /data/factory/iso/Fedora-Server-netinst-x86_64-22_Beta_RC3

The rest of the steps should be the same.

## Keeping all data on the host system

If you want to keep all the data in the host system and you don't want to use Volume Container, then instead of [Create directory structure] run:

    cp -a openqa_data/data.template data
    chcon -Rt svirt_sandbox_file_t data

In the [Run the Data & WebUI containers] section don't run `openqa_data` container and run the `webui` container like this instead:

    docker run -d -h openqa_webui -v `pwd`/data:/data --name openqa_webui -p 443:443 -p 80:80 fedoraqa/openqa_webui:4.1-3.12

Change OpenID provider in `data/conf/openqa.ini` under `provider` in `[openid]` section and then put Key and Secret under
both sections in `data/conf/client.conf`.

In the [Run the Worker container] section, run worker as:

    docker run -h openqa_worker_1 --name openqa_worker_1 -d --link openqa_webui:openqa_webui -v `pwd`/data:/data --volumes-from openqa_webui --privileged fedoraqa/openqa_worker:4.1-3.12 1

Then continue with tests and ISOs downloading as before.

## Developing tests with Container setup

With this setup, the needles created from the WebUI will almost certainly have different owner and group than your user account.
As we have the tests in GIT, and still want to retain the original owner and permission, even as we update/create needles from OpenQA.
To accomplish this, we are using BindFS. An example entry in `/etc/fstab`:

    bindfs#/home/jskladan/src/openQA/openqa_fedora    /home/jskladan/src/openQA/openqa_fedora_tools/docker/data/tests/fedora    fuse    create-for-user=jskladan,create-for-group=jskladan,create-with-perms=664:a+X,perms=777    0    0

Mounts the `openqa_fedora` directory to the `.../tests/fedora directory`. All files in the `tests/fedora` directory seem to have 777 permissions set, but new files are created (in the underlying `openqa_fedora` directory) with `jskladan:jskladan` user and group, and 664:a+X permissions.
