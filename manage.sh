#!/bin/bash -x

source functions.sh

if [ $# -lt 1 ]
then
  echo "Usage: $0 [cleanup|snapshot-nodes <name>|revert-nodes <name>]"
  exit 1
fi

OPERATION=$1

case "$OPERATION" in

 "cleanup")
  echo "Cleaning up..."
  master_name="fuel-master-${env_number}"
  slave_name_prefix="fuel-slave-${env_number}"
  remove_master $master_name
  remove_slaves $slave_name_prefix
 ;;
 "snapshot-nodes")
  echo "Snapshotting nodes..."
  SNAP_NAME=$2

  for i in $(virsh list | grep fuel- | awk '{print $2}')
  do
    virsh suspend $i
  done

  for i in $(virsh list | grep fuel- | awk '{print $2}')
  do
    virsh snapshot-create-as $i $SNAP_NAME
  done
 ;;
  "revert-nodes")
  echo "Reverting nodes..."
  SNAP_NAME=$2

  for i in $(virsh list | grep fuel- | awk '{print $2}')
  do
    virsh snapshot-revert $i $SNAP_NAME
  done

  for i in $(virsh list | grep fuel- | awk '{print $2}')
  do
    virsh resume $i
  done

 ;;
  *)
  echo "Unsupported command"
  echo "Usage: $0 [cleanup|snapshot-nodes <name>|revert-nodes <name>]"
  exit 1
esac
