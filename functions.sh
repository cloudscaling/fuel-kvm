#!/bin/bash

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
    local path="/var/lib/libvirt/images"
    virsh pool-define-as default dir - - - - "$path"
    virsh pool-build default
    virsh pool-start default
    virsh pool-autostart default
}

function create_network {
    local NET=$1
    virsh net-destroy ${NET} 2> /dev/null || true
    virsh net-undefine ${NET} 2> /dev/null || true
    virsh net-define ${NET}.xml
    virsh net-autostart ${NET}
    virsh net-start ${NET}
}

function setup_network {
    TMPD=$(mktemp -d)
    IMAGE_PATH=$(get_pool_path default)
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
}

function get_vnc() {
   domain=$1
   VNC_PORT=$(virsh vncdisplay $domain | awk -F ":" '{print $2}' | sed 's/\<[0-9]\>/0&/')
   echo "59${VNC_PORT}"
}

function remove_master () {
     name=$1
     master=$(virsh list --all | grep $name | awk '{print $2}')
     if [[ ! -z "$master" ]]
     then
         echo "Deleting Fuel Master vm..."
         for j in $(virsh snapshot-list $name | awk '{print $1}' | tail -n+3)
         do
            virsh snapshot-delete $name $j
         done
         virsh destroy $name
         virsh undefine $name
         virsh vol-delete --pool default ${name}.qcow2
     fi
     pool_path=$(get_pool_path default)
     if [[ -z "$pool_path" ]]; then return; fi
     master=$(virsh vol-list --pool default | grep $name | awk '{print $2}')
     if [[ ! -z "$master" ]]
     then
          virsh vol-delete --pool default ${name}.qcow2
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

   pool_path=$(get_pool_path default)
   if [[ -z "$pool_path" ]]; then return; fi
   for i in $(virsh vol-list --pool default | grep $name | awk '{print $1}')
   do
      virsh vol-delete --pool default $i
   done
}
