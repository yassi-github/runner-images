#!/bin/bash

help_msg() {
    echo -e "Usage:"
    echo -e "\tcreate-vm.sh [<vm-macaddress> | "auto"] <image-size> <net-type> [portfwd]"
    echo -e "Example:"
    echo -e "\tcreate-vm.sh "vm:ma:ca:dd:re:ss" "86G" "public" "127.0.0.1:8080:80,127.0.0.1:8022:22""
    echo -e "Notes:"
    echo -e "\tVM name is current directory name."
    echo -e "\tTo change vcpus, ram, os variant, base image uri(path), and storage pool path, edit the config_vars func manually."
    echo -e "Requirements:"
    echo -e "\tpackage: genisoimage"
    echo -e "\tpermission: to run virt-install, and to write storage pool path files"
}

config_vars() {
    vcpus="2"
    ram="4096"
    # Use the command "osinfo-query os" to get the list of the accepted OS variants.
    os_variant="ubuntu20.04"
    # http or filepath
    storage_pool_path="/var/lib/libvirt/images"
    cloud_img_uri="../images/linux/output-ubuntu/packer-ubuntu"
    vm_hostname="${PWD##*/}"
    github_username=yassi-github
    vm_username="runner"
    vm_base_image_file_path="${storage_pool_path}/base/${cloud_img_uri##*/}"
    vm_image_file_path="${storage_pool_path}/${vm_hostname}/${vm_hostname}.qcow2"
    vm_cidata_file_path="${storage_pool_path}/${vm_hostname}/${vm_hostname}-cidata.iso"

    # extract default gw
    # brname: "virbr0"
    brname=$(virsh net-dumpxml --network ${network_type} | grep '^  <bridge' | grep 'name=' | sed "s%^.*name='\([^']\+\).*$%\1%")
    # braddr: "192.168.122.1/24"
    braddr=$(ip a show ${brname} | grep -Po 'inet \K[\d\./]+')
    # net_defaultgw: "192.168.122.1"
    net_defaultgw=$(awk "/^[^I]/ {if (\$1==\"${brname}\") print \$3}" /proc/net/route | grep -v "00000000" |  xxd -r -p | hexdump -e '/1 "%u."' | tac -s'.' | sed 's/\.$//')
    [ -z ${net_defaultgw} ] && net_defaultgw="${braddr%%/*}"
}

input_validate() {
    if [[ $# < 3 ]] || [[ $# > 4 ]]; then ERRMSG="pls fill args (help: -h)"; return 1; fi
    # args
    # "aa:bb:cc:dd:ee:ff" or "auto"
    vm_mac_address="${1}"
    shift
    # "5G"
    vm_size="${1}"
    shift
    # "default"
    network_type="${1}"
    shift
    # "hostAddress:hostPort:guestPort,,"
    # "127.0.0.1:8080:80,127.0.0.1:8022:22"
    portfwd_all="${1}"
    
    if [[ "${vm_mac_address}" == "auto" ]]; then
        # random mac address
        # qemu oui is "52:54:00"
        vm_mac_address=$(hexdump -n3 -e'/1 "52:54:00" 3/1 ":%02x"' /dev/random)
    fi
    macaddress_regexp="^([0-9a-z]{2}:){5}[0-9a-z]{2}"
    if [[ ! "${vm_mac_address}" =~ $macaddress_regexp ]]; then
        echo "invalid mac address"
        return 1
    fi

    shopt -s extglob
    available_net_pattern='@('$( virsh net-list --name | tr '\n' '|' )')'
    case "${network_type}" in
        ${available_net_pattern} ) ;;
        * )
            echo "the libvirt net \"${network_type}\" is not available."
            return 1
        ;;
    esac
    shopt -u extglob
}

generate_clouddata() {
    cp user-data{.skl,}
    cp meta-data{.skl,}
    cp network-config{.skl,}
    sed -i "s/{{ vm_hostname }}/${vm_hostname}/g" user-data meta-data
    sed -i "s/{{ vm_username }}/${vm_username}/g" user-data
    sed -i "s/{{ github_username }}/${github_username}/g" user-data
    sed -i "s/{{ default_gw }}/${net_defaultgw}/g" network-config
    sed -i "s/{{ vm_mac_address }}/${vm_mac_address}/g" network-config
}

locate_cloudimg() {
    mkdir -p "${storage_pool_path}/base/" "${storage_pool_path}/${vm_hostname}/"
    echo "copying base image to libvirt base image directory...(this may take a while)"
    [[ -e "${cloud_img_uri}" ]] && cp -u "${cloud_img_uri}" "${vm_base_image_file_path}" || sh -c 'echo "base image copy failed."; exit 1'
}

create_disk() {
    vm_base_image_file_size=$(ls -l ${vm_base_image_file_path} | awk '{print $5}')
    vm_size_bytes=$(numfmt --from iec "${vm_size}")
    if [[ ${vm_base_image_file_size} -ge ${vm_size_bytes} ]]; then
        echo "too small vm size. must bigger than $(numfmt --to iec ${vm_base_image_file_size})"
        return 1
    fi
    qemu-img create -f qcow2 -b "${vm_base_image_file_path}" -F qcow2 "${vm_image_file_path}"
    qemu-img resize "${vm_image_file_path}" "${vm_size}"
    mkisofs -o "${vm_cidata_file_path}" -V cidata -R user-data meta-data network-config
}

vm_install() {
    virt-install \
    --name "${vm_hostname}" \
    --vcpus "${vcpus}" --ram "${ram}" \
    --hvm --virt-type kvm \
    --os-variant "${os_variant}" \
    --graphics none --serial pty --console pty \
    --import --noreboot \
    --disk path="${vm_image_file_path}" \
    --disk path="${vm_cidata_file_path}",device=cdrom \
    --network network="${network_type}",model=virtio,mac="${vm_mac_address}"

    # edit xml
    ## port forward (TCP only)
    if [[ "${portfwd_all}" != "" ]]; then
        # net_range: "192.168.122.0/24"
        net_range="$(python3 -c 'import ipaddress; print(str(ipaddress.ip_network('\"${braddr}\"', False)))')"

        hostfwd_all=""
        for PORTFWD in ${portfwd_all//','/' '}; do
            hostfwd_all+=","
            # 127.0.0.1:8080
            port_forward_host=$(echo "${PORTFWD}" | cut -d':' -f1-2)
            # 80
            port_forward_guest=$(echo "${PORTFWD}" | cut -d':' -f3)
            qemu_commandline_hostfwd="hostfwd=tcp:${port_forward_host}-:${port_forward_guest}"
            hostfwd_all+="${qemu_commandline_hostfwd}"
        done

        virt-xml "${vm_hostname}" --edit --qemu-commandline "-netdev user,id=portforwardingnic,net=${net_range}${hostfwd_all}"
        virt-xml "${vm_hostname}" --edit --qemu-commandline "\-device rtl8139,netdev=portforwardingnic,mac=88:88:88:88:88:88"
    fi
}

vm_start() {
    virsh start "${vm_hostname}"
    echo
    echo -e "You can enter vm console by:"
    echo -e "\tvirsh console ${vm_hostname}"
}

main() {
    local subcmd="${1:-help}"
    case "${subcmd}" in
        "-h")
            help_msg
        ;;
        "--help")
            help_msg
        ;;
        "help")
            help_msg
        ;;
        *)
            input_validate "${@}"
            config_vars
            generate_clouddata
            locate_cloudimg
            create_disk
            vm_install
            vm_start
        ;;
    esac
}

set -e
main "${@}"
exit $?
