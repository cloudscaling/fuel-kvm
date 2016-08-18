#!/bin/bash -x

source functions.sh

if [ $# -ne 4 ]
then
  echo "Usage: $0 node_name node_ram node_cpu node_size"
  exit 1
fi

name=$1
ram=$2
cpu=$3
size=$4
net_driver=${net_driver:-e1000}
hosts_bridge=false

fuel_pxe="fuel-pxe-$env_number"
fuel_public="fuel-public-$env_number"
fuel_external="fuel-external-$env_number"
if $hosts_bridge
then
  external_network=$fuel_external
else
  external_network=$fuel_public
fi

echo "Creating storage..."

virsh vol-create-as --name ${name}.qcow2 --capacity $size --format qcow2 --allocation $size --pool $poolname
virsh vol-create-as --name ${name}2.qcow2 --capacity $size --format qcow2 --allocation $size --pool $poolname
virsh vol-create-as --name ${name}3.qcow2 --capacity $size --format qcow2 --allocation $size --pool $poolname
pool_path=$(get_pool_path $poolname)

echo "Starting Fuel slave vm..."

virt-install \
  --name=$name \
  --ram=$ram \
  --vcpus=$cpu,cores=$cpu \
  --os-type=linux \
  --virt-type=kvm \
  --pxe \
  --boot network,hd \
  --disk "$pool_path/${name}.qcow2",cache=writeback,bus=virtio,serial=$(uuidgen) \
  --disk "$pool_path/${name}2.qcow2",cache=writeback,bus=virtio,serial=$(uuidgen) \
  --disk "$pool_path/${name}3.qcow2",cache=writeback,bus=virtio,serial=$(uuidgen) \
  --noautoconsole \
  --network network=$fuel_pxe,model=$net_driver \
  --network network=$external_network,model=$net_driver \
  --graphics vnc,listen=0.0.0.0 \
#  --cpu host
#If cpu parameter is set to "host" with QEMU 2.0 hypervisor
#it causes critical failure during CentOS installation

virsh destroy $name
setup_cache $name
virsh start $name

echo "VNC port: $(get_vnc $name)"
