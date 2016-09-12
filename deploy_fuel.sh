#!/bin/bash -x

source functions.sh

if [ $# -ne 2 ]
then
  echo "Usage: $0 iso-path #nodes"
  exit 1
fi

#Set virtual interfaces driver for VMs
#export net_driver=virtio

#Fuel master node
master_name="fuel-master-${env_number}"
master_ram=6000
master_cpu=2
master_disk=100G
iso_path=$1

#Cluster nodes
node_name="fuel-slave-${env_number}"
node_ram=10000
node_cpu=4
node_size=100G
node_count=$2

#Check and install required packages
check_packages

#Remove old VMs
remove_master $master_name
remove_slaves $node_name

#Deploy Fuel master node
./deploy_master.sh $iso_path $master_name $master_ram $master_cpu $master_disk || exit 1

#Start slaves
if [ $node_count -eq 0 ]; then
  echo "WARNING: No slaves will be created"
else
  echo "Starting slaves..."
  for (( i=1; i<=$node_count; i++ ))
  do
     ./deploy_slave.sh $node_name-$RANDOM $node_ram $node_cpu $node_size
  done
fi

echo "Deployment was finished"

