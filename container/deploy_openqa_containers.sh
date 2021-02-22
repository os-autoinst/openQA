#!/bin/bash
set -e

FORCE=0
PREFIX="openqa"
NETWORK="${PREFIX}_net"
PORT="80"
ACTION=""
WEBUI_IMAGE="registry.opensuse.org/devel/openqa/containers15.2/openqa_webui:latest"
WORKER_IMAGE="registry.opensuse.org/devel/openqa/containers15.2/openqa_worker:latest"

function wait_for_container_ready {
  container=$1

  for ((count=0; count<30; count++))
  do
    sleep 1
    if docker inspect openqa2_db | grep '"Status": "running"' >/dev/null; then
      echo "OK - Container $container started correcty"
      break
    fi
  done
}

function wait_for_container_appropiate_logs {
  container=$1
  message=$2

  if [ -n "$3" ]; then
    countMax=$(($3))
  else  
    countMax=30
  fi

  for ((count=0; count<countMax; count++))
  do
    if docker logs "$container" 2>&1 | grep "$message" >/dev/null; then
      echo "OK - Container $container stand-up correctly - found in logs $message"
      break
    fi    
  done

  if [[ $count -eq countMax ]]; then
    echo "ERROR - Sorry the container $container didn't stand-up correctly"
    exit 2
  fi
}

function show_usage {
  echo "Usage: $0 [options] <action>"
  echo "Actions:"
  echo " - prepare, prepare the environment. If uses --force the current directories will be removed and recreated"
  echo " - db, create the database container. If uses --force the current db container will be removed and recreated"
  echo " - webui, create the webui container. If uses --force the current configuration and webui container will be removed and ecreated"
  echo " - worker, create the worker container If uses --force the current configuration and worker container will be removed and ecreated"
  echo "Options:"
  echo "-f|--force, destroys and recreate the previous data or container associated to the action"
  echo "--key, api key. Required deploying the worker"
  echo "--secret, api secret. Required deploying the worker"
  echo "--prefix [network_name], set a prefix network and container creation (the default is openqa)"
  echo "--port, changes the port for the UI (default 80)"
  echo "--webui-image, to select what image will be used for the webui container (the default  is registry.opensuse.org/devel/openqa/containers15.2/openqa_webui:latest)"
  echo "--worker-image, to select what image will be used for the worker container (the default is registry.opensuse.org/devel/openqa/containers15.2/openqa_worker:latest)"
  echo "Notes:"
  echo "  For initial deployments execute in order the actions: prepare, db, webui, worker"
}

function prepare {
  [[ $FORCE -eq 1 ]] && rm -rf data 2>/dev/null
  mkdir -p data/factory/{iso,hdd,other,tmp} data/{testresults,tests,conf} data/certs/{ssl.crt,ssl.key}
  chmod a+w data/testresults

  [[ $FORCE -eq 1 ]] && docker network inspect "$NETWORK" >/dev/null 2>&1 && docker network rm "$NETWORK" >/dev/null
  docker network create "$NETWORK" >/dev/null || exit 1
  
  echo "Next step (db), creation of the data base"
}

function db {
  CONT_NAME="${PREFIX}_db"

  [[ $FORCE -eq 1 ]] && set +e && docker rm -f "$CONT_NAME" >/dev/null 2>&1; set -e
  docker run -d --network "$NETWORK" -e POSTGRES_PASSWORD=openqa -e POSTGRES_USER=openqa -e POSTGRES_DB=openqa --net-alias=db --name "$CONT_NAME" postgres >/dev/null

  wait_for_container_ready "$CONT_NAME"
  wait_for_container_appropiate_logs "$CONT_NAME" "database system is ready to accept connections"

  echo "Next step (webui), stand-up the webui"
}

function webui {
  [[ ! -d data ]] && echo "Please execute first prepare command" && exit 1

  CONT_NAME="${PREFIX}_webui"
  
  pushd .
  cd data/conf || exit 1
  wget https://raw.githubusercontent.com/os-autoinst/openQA/master/container/webui/conf/openqa.ini >/dev/null
  cp openqa.ini /tmp/
  sed 's/method = OpenID/method = Fake/' </tmp/openqa.ini >openqa.ini
  wget https://raw.githubusercontent.com/os-autoinst/openQA/master/container/webui/conf/database.ini  >/dev/null
  wget https://raw.githubusercontent.com/os-autoinst/openQA/master/container/openqa_data/data.template/conf/client.conf >/dev/null
  popd || exit 1

  openssl req -newkey rsa:4096 -x509 -sha256 -days 365 -nodes -subj '/CN=www.mydom.com/O=My Company Name LTD./C=DE' \
    -out data/certs/ssl.crt/server.crt -keyout data/certs/ssl.key/server.key >/dev/null

  cp data/certs/ssl.crt/server.crt data/certs/ssl.crt/ca.crt

  volumes="-v $(pwd)/data:/data"
  certificates="-v $(pwd)/data/certs/ssl.crt:/etc/apache2/ssl.crt -v $(pwd)/data/certs/ssl.key:/etc/apache2/ssl.key"

  [[ $FORCE -eq 1 ]] && set +e && docker rm -f "$CONT_NAME" 2>/dev/null 2>&1; set -e
  docker run -d --network "$NETWORK" $volumes $certificates -p $PORT:80 --net-alias=openqa_webui --name "$CONT_NAME" "$WEBUI_IMAGE" || exit 1
  
  wait_for_container_ready "$CONT_NAME"
  wait_for_container_appropiate_logs "$CONT_NAME" 'Listening at "http://127.0.0.1:9527"'
  wait_for_container_appropiate_logs "$CONT_NAME" 'Listening at "http://127.0.0.1:9528"'
  wait_for_container_appropiate_logs "$CONT_NAME" 'Listening at "http://127.0.0.1:9529"'
  wait_for_container_appropiate_logs "$CONT_NAME" 'Web application available at'
  
  echo "Next step (worker), stand-up of worker container"
  echo "You have to provide an API key/secret. Access to the UI to create a pair at http://localhost:$PORT"
}

function worker {
  [[ -z $KEY ]] || [[ -z $SECRET ]] && echo "--key and --secret are required" && exit 1

  [[ ! -d data ]] && [[ ! -d data/conf ]] && echo "Please execute first prepare command" && exit 1

  CONT_NAME="${PREFIX}_worker"

  pushd .
  cd data/conf
  wget https://raw.githubusercontent.com/os-autoinst/openQA/master/container/openqa_data/data.template/conf/workers.ini >/dev/null 2>/dev/null
  popd || exit 1

  echo -e "[openqa_webui]\nkey = $KEY\nsecret = $SECRET" > data/conf/client.conf

  [[ $FORCE -eq 1 ]] && set +e && docker rm -f "$CONT_NAME" >/dev/null 2>&1 && set -e
  docker run -d --network "$NETWORK" -v "$(pwd)/data:/data" --device=/dev/kvm --privileged --name "$CONT_NAME" "$WORKER_IMAGE" >/dev/null

  wait_for_container_ready "$CONT_NAME"
  wait_for_container_appropiate_logs "$CONT_NAME" 'Registering with openQA'  
  echo -n "Checking if API credentials are correct.. ."
  wait_for_container_appropiate_logs "$CONT_NAME" 'Registered and connected via websockets with openQA' 4

  echo "All ready. Enjoy!"
  echo "You have to provide your own tests or the upstream tests and neeles and store them in the directory data/tests"
  echo "e.g. of usage: docker exec -ti ${PREFIX}_webui /usr/share/openqa/script/clone_job.pl --apikey $KEY --apisecret $SECRET <upstream_job>"
}

function clean {
  set +e
  docker rm -f "${PREFIX}_worker"
  docker rm -f "${PREFIX}_webui"
  docker rm -f "${PREFIX}_db"
  docker network rm "$NETWORK"
  [[ -d data ]] && rm -rf data
}

[[ $# -lt 1 ]] && show_usage && exit 1

while [ -n "$1" ];do
  case "$1" in
    -h|--help)
      show_usage
      ;;
    --prefix)
      shift
      PREFIX="$1"
      NETWORK="${PREFIX}_net"
      ;;
    -f|--force)
      FORCE=1
      ;;
    --key)
      shift
      KEY="$1"
      ;;
    --secret)
      shift
      SECRET="$1"
      ;;
    --port)
      shift
      PORT="$1"
      ;;
    --webui-image)
      shift
      WEBUI_IMAGE=$1
      ;;
    --worker-image)
      shift
      WORKER_IMAGE=$1
      ;;
    prepare | db | webui | worker | clean)
      ACTION="$1"
      ;;
    *)
      echo "Incorrect input provided $1"
      show_usage
      exit 1
  esac
shift
done

case "$ACTION" in
  prepare)
    prepare
    ;;
  db)
    db
    ;;
  webui)
    webui
    ;;
  worker)
    worker
    ;;
  clean)
    clean
    ;;
  *)
    echo "Invalid action $ACTION"
    show_usage
    exit 1
esac
