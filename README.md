# GitHub Actions Runner Image for QEMU

Build [actions/runner](https://github.com/actions/runner-images) image by QEMU instead of Azure VM.

## TLDR

```bash
# Build image
# If credentials are provided, attempt to log into Docker Hub
DOCKERHUB_LOGIN="your dockerhub username"
DOCKERHUB_PASSWORD="your dockerhub password"
sed "s%{{ ssh_pem_pubkey }}%$(cat ~/.ssh/id_rsa.pub)%" cloud-data/user-data.skl > cloud-data/user-data
cd images/linux/
packer init ubuntu2204.pkr.hcl
packer build ubuntu2204.pkr.hcl
# Start VM
cd ../../launcher
sed -i "s/github_username=.*/github_username=$(git config user.name)/" create-vm.sh
sudo ./create-vm.sh auto 86G default
virsh console launcher
```

## Requirements

to build image:

- packer
- qemu

to launch script:

- libvirt
- virt-install
- genisoimage

## Usage

Create runner image:

1. Set your ssh pubkey (PEM format) to `{{ ssh_pem_pubkey }}` at `cloud-data/user-data` file copied from `cloud-data/user-data.skl`
1. Please change vm resource(cpu,memory,disk size) to suit your environment by editing `qemu-ubuntu.pkr.hcl`.  
    The official repo is using `Standard_D4s_v4` (vcpu 4, memory 16G) and 86Gb disk size vm.  
    Note that disk size 64G is too small to packer build.
    ```
    cpus                 = "4"
    memory               = "16384"
    disk_size            = "86G"
    ```
1. Go to `images/linux/` dir
1. Install packer plugin by `packer init ubuntu2204.pkr.hcl`
1. Build base image by `packer build ubuntu2204.pkr.hcl`
1. The runner image will created under `output-ubuntu/` directory

Launch the runner image:

1. Go to `launch/` dir
1. Edit config variables at `create-vm.sh`
    - vcpus, ram, github_username, etc.
1. Create vm image (backing built image) by `create-vm.sh` script
    - Example: `sudo ./create-vm.sh auto 5G default` (see details: `./create-vm.sh help`)
1. Now you can enter vm via `ssh` or `virt console`

## How it works

1. packer builds base image
    1. initial user is created by cloud-init at `cloud-data/` (initial user is only used for this building)
    1. files and scripts (copied from [official](https://github.com/actions/runner-images)) are proceed by packer via your local ssh
    1. created base image is created at `output-ubuntu/`
1. launcher script (`create-vm.sh`) creates vm image disk file and starts it
    1. creates cloud-init config to create runner user
    1. created cloud config is embedded with vm image as cidata to run cloud-init
    1. starts vm

## Changed points

- Use QEMU instead of Azure VM

- Add `cloud-data/` to prepare initial config

- Add `launcher/` to demonstrate launching vm

- Delete Azure related variables in pkr file

- Add clean-up provisioner to enable to start launcher cloud-init(`launcher/user-data`)
