#!/bin/bash

vm_name="${PWD##*/}"

virsh destroy "${vm_name}" && sleep 5s
virsh undefine "${vm_name}" --remove-all-storage
virsh pool-destroy "${vm_name}"
virsh pool-delete "${vm_name}"
virsh pool-undefine "${vm_name}"

rm -f user-data meta-data network-config
