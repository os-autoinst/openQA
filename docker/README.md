# Build docker images

    docker build -t fedoraqa/openqa_webui ./webui
    docker build -t fedoraqa/openqa_worker ./worker
    docker build -t fedoraqa/openqa_data ./openqa_data

# Running OpenQA

Our intent was to create universal `webui` and `worker` containers and move all data storage and configurations to third container,
called `openqa_data`. `openqa_data` is so called [Data Volume Container](http://docs.docker.com/userguide/dockervolumes/#creating-and-mounting-a-data-volume-container)
and is used as database, results and configuration storage. During development and in production, you could update `webui` and `worker` images
but as long as `openqa_data` is intact, you don't lose any data.

To make development easier and to reduce final size of `openqa_data` container, this guide describes how to override `tests` and `factory` directories
with directories from your host system. It's not necessary, but it's recommended and this guide is written with this setup in mind.

It's also possible to use `tests` and `factory` from within the `openqa_data` container (so you don't have any dependency on your host system) or
to ditch `openqa_data` container altogether (so you have only `webui` and `worker` containers and data is loaded and saved completely into your host
system). If this is what you want, refer to [Keeping all data in the Data Volume Container] and [Keeping all data on the host system] sections respectively.

## Create directory structure

    mkdir -p data/factory/{iso,hdd} data/tests

It is also necessary to either run all containers in privileged mode, or set selinux properly:

    chcon -Rt svirt_sandbox_file_t data

## Run the Data & WebUI containers

    docker run -d -h openqa_data --name openqa_data -v `pwd`/data/factory:/data/factory -v `pwd`/data/tests:/data/tests fedoraqa/openqa_data
    docker run -d -h openqa_webui --volumes-from openqa_data --name openqa_webui -p 8080:443 fedoraqa/openqa_webui

It is now necessary to create and store the client keys for OpenQA. In the next two steps, you will set an OpenID provider (if necessary),
create the API keys in the OpenQA's web interface, and store the configuration in the Data Container.

### Change the OpenID provider

https://id.fedoraproject.org/ is set as a default OpenID provider. To change it, run:

    docker exec -ti openqa_data /scripts/set_openid

and enter the Provider's URL.

### Set API keys

Go to https://localhost:8080/api_keys, generate key and secret. Then run:

    docker exec -ti openqa_data /scripts/set_keys

and enter the Key and Secret.

## Run the Worker container

    docker run -h openqa_worker_1 --name openqa_worker_1 -d --link openqa_webui:openqa_webui --volumes-from openqa_data --volumes-from openqa_webui --privileged fedoraqa/openqa_worker 1

Check whether the worker connected in the WebUI's administration interface.

To add more workers, increase number that is used in hostname, container name and at the end of command, so to add worker 2 use:

    docker run -h openqa_worker_2 --name openqa_worker_2 -d --link openqa_webui:openqa_webui --volumes-from openqa_data --volumes-from openqa_webui --privileged fedoraqa/openqa_worker 2

## Get tests and ISOs

You have to put your tests under `data/tests` directory and ISOs under `data/factory/iso` directory. For example, for testing Fedora, run:

    git clone https://bitbucket.org/rajcze/openqa_fedora data/tests/fedora
    wget https://dl.fedoraproject.org/pub/alt/stage/22_Beta_RC3/Server/x86_64/iso/Fedora-Server-netinst-x86_64-22_Beta.iso -O data/factory/iso/Fedora-Server-netinst-x86_64-22_Beta_RC3

And set permissions, so any user can read/write the data:

    chmod -R 777 data

This step is unfortunately necessary because Docker [can't mount volume with specific user ownership](https://github.com/docker/docker/issues/7198) in container, so ownership of mounted folders (uid and gid) is the same as on your host system (presumably 1000:1000 which maps into nonexistent user in all of the containers).

If you wish to keep the tests (for example) separate from the shared directory, for any reason (we do, in our development scenario) refer to the [Developing tests with Container setup] section at the end of this document.

Populate the OpenQA's database:

    docker exec openqa_webui /var/lib/openqa/tests/fedora/templates


# Running jobs

After performing the "setup" tasks above - do not forget about tests and ISOs - you can schedule a test like this:

    docker exec openqa_webui /var/lib/openqa/script/client isos post ISO=Fedora-Server-netinst-x86_64-22_Beta_RC3.iso DISTRI=fedora VERSION=rawhide FLAVOR=generic_boot ARCH=x86_64 BUILD=22_Beta_RC3

# Other specific cases

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

    docker run -d -h openqa_webui -v `pwd`/data:/data --name openqa_webui -p 8080:443 fedoraqa/openqa_webui

Change OpenID provider in `data/conf/openqa.ini` under `provider` in `[openid]` section and then put Key and Secret under
both sections in `data/conf/client.conf`.

In the [Run the Worker container] section, run worker as:

    docker run -h openqa_worker_1 --name openqa_worker_1 -d --link openqa_webui:openqa_webui -v `pwd`/data:/data --volumes-from openqa_webui --privileged fedoraqa/openqa_worker 1

Then continue with tests and ISOs downloading as before.

## Developing tests with Container setup

With this setup, the needles created from the WebUI will almost certainly have different owner and group than your user account.
As we have the tests in GIT, and still want to retain the original owner and permission, even as we update/crate needles from OpenQA.
To accomplish this, we are using BindFS. An example entry in `/etc/fstab`:

    bindfs#/home/jskladan/src/openQA/openqa_fedora    /home/jskladan/src/openQA/openqa_fedora_tools/docker/data/tests/fedora    fuse    create-for-user=jskladan,create-for-group=jskladan,create-with-perms=664:a+X,perms=777    0    0

Mounts the `openqa_fedora` directory to the `.../tests/fedora directory`. All files in the `tests/fedora` directory seem to have 777 permissions set, but new files are created (in the underlying `openqa_fedora` directory) with `jskladan:jskladan` user and group, and 664:a+X permissions.
