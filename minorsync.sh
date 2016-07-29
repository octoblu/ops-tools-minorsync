#!/bin/bash

describe_aws_instance() {
  aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=service-minor-cluster"
}

get_minor_ip(){
  describe_aws_instance \
    | jq -r '.Reservations[].Instances[].PublicIpAddress' \
    | grep -v null \
    | head -n 1
}

establish_ssh_tunnel(){
  local ip_address="$1"

  ssh -t -t -L 45000:localhost:2379 "core@$ip_address" &> /dev/null
}

kill_ssh_tunnel_job() {
  local parent_pid="$1"
  pkill -P "$parent_pid" -f 'ssh -t -t -L 45000:localhost:2379'
}

do_etcd_sync(){
  local namespace="$1"
  local project="$2"
  local cmd="$3"
  local full_namespace="/$namespace/$project"

  env \
    ETCDSYNC_TABLE=true \
    ETCDSYNC_INCLUDE_DIRECTORIES=true \
    etcdsync \
      --etcd-uri http://localhost:45000 \
      --local-path "$HOME/Projects/Octoblu/the-stack-env-production/minor/etcd" \
      --namespace "$full_namespace" \
      "$cmd"
}

wait_for_tunnel() {
  local tunnel_open="1"
  while [ "$tunnel_open" != "0" ]; do
    echo -n "."
    curl http://localhost:45000 &> /dev/null
    tunnel_open="$?"
    sleep 0.25
  done
  echo ""
}

assert_port_free() {
  curl http://localhost:45000 &> /dev/null
  local exit_code="$?"
  if [ "$exit_code" == "0" ]; then
    echo "Port 45000 seems to be in use, cowardly refusing to do anything"
    exit 1
  fi
}

usage(){
  echo "USAGE: minorsync [options] <dump/gd/gload/l/printfs/pf/printetcd/pe> <project-name>"
  echo ""
  echo "example: minorsync load governator-service"
  echo "use env NAMESPACE to change from 'octoblu' to something else"
  echo ""
  echo "  -h, --help      print this help text"
  echo "  -v, --version   print the version"
  echo ""
}

script_directory(){
  local source="${BASH_SOURCE[0]}"
  local dir=""

  while [ -h "$source" ]; do # resolve $source until the file is no longer a symlink
    dir="$( cd -P "$( dirname "$source" )" && pwd )"
    source="$(readlink "$source")"
    [[ $source != /* ]] && source="$dir/$source" # if $source was a relative symlink, we need to resolve it relative to the path where the symlink file was located
  done

  dir="$( cd -P "$( dirname "$source" )" && pwd )"

  echo "$dir"
}

version(){
  local directory="$(script_directory)"
  local version=$(cat "$directory/VERSION")

  echo "$version"
  exit 0
}

validate_cmd() {
  local cmd="$1"

  if [ "$cmd" == "dump" -o "$cmd" == "d" ]; then
    return
  fi

  if [ "$cmd" == "load" -o "$cmd" == "l" ]; then
    return
  fi

  if [ "$cmd" == "printfs" -o "$cmd" == "pf" ]; then
    return
  fi

  if [ "$cmd" == "printetcd" -o "$cmd" == "pe" ]; then
    return
  fi

  echo "Command must be one of dump/gd/gload/l/printfs/pf/printetcd/pe"
  usage
}

main(){
  local cmd="$1"
  local project="$2"
  local namespace="${NAMESPACE:-octoblu}"

  if [ "$cmd" == "--help" -o "$cmd" == "-h" ]; then
    usage
    exit 0
  fi

  if [ "$cmd" == "--version" -o "$cmd" == "-v" ]; then
    version
    exit 0
  fi

  validate_cmd "$cmd"
  assert_port_free

  local ip_address="$(get_minor_ip)"
  establish_ssh_tunnel "$ip_address" & # in the background
  local ssh_tunnel_job="$!"

  echo -n "Waiting for tunnel"
  wait_for_tunnel
  echo "Tunnel established, working."
  do_etcd_sync "$namespace" "$project" "$cmd"
  local exit_code=$?

  kill_ssh_tunnel_job "$ssh_tunnel_job"

  exit $exit_code
}

main $@
