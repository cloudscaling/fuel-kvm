#!/bin/bash

env_number=${FUEL_ENV_NUMBER:-'0'}
poolname=${FUEL_VOLUME_POOL:-'fuel-images'}

function check_packages {
    PACKAGES="sshpass qemu-utils lvm2 libvirt-bin virtinst qemu-kvm e2fsprogs"
    apt-get update
    for i in $PACKAGES; do
       dpkg -s $i &> /dev/null || apt-get install -y --force-yes $i
    done
}

function get_pool_path {
    local pool=$1
    local path
    virsh pool-info $pool &>/dev/null || return
    path=$(virsh pool-dumpxml $pool | sed -n '/path/{s/.*<path>\(.*\)<\/path>.*/\1/;p}')
    echo $path
}

function create_pool {
    local path="/var/lib/libvirt/images/$poolname"
    virsh pool-define-as $poolname dir - - - - "$path"
    virsh pool-build $poolname
    virsh pool-start $poolname
    virsh pool-autostart $poolname
}

function create_network {
    local NET=$1
    make_network_xml $NET
    virsh net-destroy ${NET} 2> /dev/null || true
    virsh net-undefine ${NET} 2> /dev/null || true
    virsh net-define /tmp/${NET}.xml
    virsh net-autostart ${NET}
    virsh net-start ${NET}
}

function setup_network {
    TMPD=$(mktemp -d)
    IMAGE_PATH=$(get_pool_path $poolname)
    name=$1
    gateway_ip=$2
    ifcfg_eth0_file=$3
    ifcfg_eth1_file=$4
    modprobe nbd max_part=63
    qemu-nbd -n -c /dev/nbd0 $IMAGE_PATH/$name.qcow2
    sleep 5
    pvscan --cache
    vgscan --mknode
    vgchange -ay os
    sleep 2
    mount /dev/os/root $TMPD
    echo -n "" > ${TMPD}/etc/sysconfig/network
    for i in "NETWORKING=yes" "HOSTNAME=fuel.domain.tld" "GATEWAY=$gateway_ip" ; do
      echo ${i} >> ${TMPD}/etc/sysconfig/network
    done
    cp $ifcfg_eth0_file $TMPD/etc/sysconfig/network-scripts/ifcfg-eth0
    cp $ifcfg_eth1_file $TMPD/etc/sysconfig/network-scripts/ifcfg-eth1
    eth0_addr=`awk -F '=' '/IPADDR/ {print($2)}' $ifcfg_eth0_file`
    sed -i "s/\(.*\)\(fuel.domain.tld\)\(.*\)/$eth0_addr   \2\3/g" $TMPD/etc/hosts
    #Fuel 6.1 and newer displays network setup menu by default
    if [[ -f ${TMPD}/root/.showfuelmenu ]]; then
      sed -i 's/showmenu=yes/showmenu=no/g' ${TMPD}/root/.showfuelmenu || true
    else
      sed -i 's/showmenu=yes/showmenu=no/g' ${TMPD}/etc/fuel/bootstrap_admin_node.conf || true
    fi
    umount $TMPD
    vgchange -an os
    qemu-nbd -d /dev/nbd0
}

function setup_cache {
    NAME=$1
    virsh dumpxml $NAME > $NAME.xml
    sed "s/cache='writeback'/cache='unsafe'/g" -i $NAME.xml
    virsh define $NAME.xml
    rm $NAME.xml
}

function is_product_vm_operational {
   ip=$1
   username=$2
   password=$3
   SSH_OPTIONS="StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
   SSH_CMD="sshpass -p ${3} ssh -o ${SSH_OPTIONS} ${2}@${1}"

   time=0
   LOG_FINISHED=""
   while [[ -z "${LOG_FINISHED}" ]]; do
       sleep 60
       time=$(($time+60))
       LOG_FINISHED=$(${SSH_CMD} "grep -o 'Fuel node deployment complete' /var/log/puppet/bootstrap_admin_node.log" 2>/dev/null)
       if [ ${time} -ge 7200 ]; then
           echo "Fuel deploy timeout"
           exit 1
       fi
   done
 
   while ! ${SSH_CMD} "fuel node" ; do
      echo wait fuel services;
      sleep 5;
   done
}

function wait_for_product_vm_to_install {
    ip=$1
    username=$2
    password=$3

    echo "Waiting for product VM to install. Please do NOT abort the script..."

    # Loop until master node gets successfully installed
    while ! is_product_vm_operational ${ip} ${username} ${password} ; do
        sleep 5
    done

    while ! ${SSH_CMD} "fuel node" ; do
       echo wait fuel services;
       sleep 5;
    done
}

function get_vnc() {
   domain=$1
   VNC_PORT=$(virsh vncdisplay $domain | awk -F ":" '{print $2}' | sed 's/\<[0-9]\>/0&/')
   echo "59${VNC_PORT}"
}

function remove_master () {
     name=$1
     master=$(virsh list --all | grep "$name " | awk '{print $2}')
     if [[ ! -z "$master" ]]
     then
         echo "Deleting Fuel Master vm..."
         for j in $(virsh snapshot-list $name | awk '{print $1}' | tail -n+3)
         do
            virsh snapshot-delete $name $j
         done
         virsh destroy $name
         virsh undefine $name
         virsh vol-delete --pool $poolname ${name}.qcow2
     fi
     pool_path=$(get_pool_path $poolname)
     if [[ -z "$pool_path" ]]; then return; fi
     master=$(virsh vol-list --pool $poolname | grep $name | awk '{print $2}')
     if [[ ! -z "$master" ]]
     then
          virsh vol-delete --pool $poolname ${name}.qcow2
     fi
}

function remove_slaves () {
   name=$1
   echo "Deleting Fuel nodes..."
   for i in $(virsh list --all | grep $name | awk '{print $2}')
   do
      for j in $(virsh snapshot-list $i | awk '{print $1}' | tail -n+3)
      do
         virsh snapshot-delete $i $j
      done
      virsh destroy $i
      virsh undefine $i
   done

   pool_path=$(get_pool_path $poolname)
   if [[ -z "$pool_path" ]]; then return; fi
   for i in $(virsh vol-list --pool $poolname | grep $name | awk '{print $1}')
   do
      virsh vol-delete --pool $poolname $i
   done
}

function make_network_xml() {
  local net_name=$1
  case "$net_name" in
    fuel-adm-pub-*)
      echo "<network><name>$net_name</name><bridge name=\"$net_name\" /><forward mode=\"nat\"/><ip address=\"172.19.$env_number.1\" netmask=\"255.255.255.0\"/></network>" >/tmp/$net_name.xml
      ;;
    fuel-public-*)
      echo "<network><name>$net_name</name><bridge name=\"$net_name\" /><forward mode=\"nat\"/><ip address=\"172.18.$env_number.1\" netmask=\"255.255.255.0\"/></network>" >/tmp/$net_name.xml
      ;;
    fuel-pxe-*)
      echo "<network><name>$net_name</name><bridge name=\"$net_name\" /><ip address=\"10.21.$env_number.1\" netmask=\"255.255.255.0\"/></network>" >/tmp/$net_name.xml
      ;;
    fuel-external*)
      echo "<network><name>$net_name</name><forward mode="bridge"/><bridge name="br0" /></network>" >/tmp/$net_name.xml
    *)
      return 1
  esac
}

function make_ifcfg_file() {
  local iface="$1"
  local iface_name=ifcfg-$iface-$env_number
  case "$iface" in
    eth0)
      echo "DEVICE=$iface
TYPE=Ethernet
ONBOOT=yes
NM_CONTROLLED=no
BOOTPROTO=static
NETWORK=10.21.$env_number.0
NETMASK=255.255.255.0
IPADDR=10.21.$env_number.2" >/tmp/$iface_name
      ;;
    eth1)
      echo "DEVICE=$iface
TYPE=Ethernet
ONBOOT=yes
NM_CONTROLLED=no
BOOTPROTO=static
NETWORK=172.19.$env_number.0
NETMASK=255.255.255.0
IPADDR=172.19.$env_number.2
DNS1=8.8.8.8" >/tmp/$iface_name
      ;;
    *)
      return 1
  esac
}

