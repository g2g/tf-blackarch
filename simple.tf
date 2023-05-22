terraform {
  required_providers {
    libvirt = {
      source = "dmacvicar/libvirt"
    }
  }
}

# variables that can be overriden
variable "username" { default = "arch" }
variable "hostname" { default = "simple" }
variable "domain" { default = "example.com" }
variable "memoryMB" { default = 1024*1 }
variable "cpu" { default = 1 }
variable "private_key_path" {
  description = "Path to the private SSH key, used to access the instance."
  #default     = "~/.ssh/id_rsa"
  default     = "./id_rsa"
}
# 20GB OS volume
variable "diskBytes" { default = 1024*1024*1024*20 }

# instance the provider
provider "libvirt" {
  uri = "qemu:///system"
}

# fetch the latest ubuntu release image from their mirrors
resource "libvirt_volume" "base_image" {
  name = "${var.hostname}-base_image.qcow2"
  pool = "default"
  #source = "https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2"
  source = pathexpand("~/iso/Arch-Linux-x86_64-cloudimg.qcow2")
  format = "qcow2"
}

resource "libvirt_volume" "os_image" {
  name = "${var.hostname}-os_image.qcow2"
  pool = "default"
  format = "qcow2"
  size = var.diskBytes
  base_volume_id = libvirt_volume.base_image.id
}

# Use CloudInit ISO to add ssh-key to the instance
resource "libvirt_cloudinit_disk" "commoninit" {
          name = "${var.hostname}-commoninit.iso"
          pool = "default"
          user_data = data.template_file.user_data.rendered
          network_config = data.template_file.network_config.rendered
}

# Generate inventory file
resource "local_file" "inventory" {
          filename = "./inventory/hosts.ini"
          file_permission = "0644"
          content = <<EOF
[all]
${libvirt_domain.domain-ubuntu.network_interface.0.addresses.0} ansible_ssh_user=${var.username} ansible_ssh_private_key_file=${var.private_key_path}
EOF
}


data "template_file" "user_data" {
  template = file("${path.module}/cloud_init.cfg")
  vars = {
    hostname = var.hostname
    fqdn = "${var.hostname}.${var.domain}"
  }
}

data "template_file" "network_config" {
  template = file("${path.module}/network_config_dhcp.cfg")
}


# Create the machine
resource "libvirt_domain" "domain-ubuntu" {
  name = var.hostname
  memory = var.memoryMB
  vcpu = var.cpu
  autostart = true
  qemu_agent = true

  disk {
       volume_id = libvirt_volume.os_image.id
  }

  network_interface {
       network_name = "default"
       wait_for_lease = true
  }

  cloudinit = libvirt_cloudinit_disk.commoninit.id

  # IMPORTANT
  # Ubuntu can hang is a isa-serial is not present at boot time.
  # If you find your CPU 100% and never is available this is why
  console {
    type        = "pty"
    target_port = "0"
    target_type = "serial"
  }

  graphics {
    type = "spice"
    listen_type = "address"
    autoport = "true"
  }

  provisioner "remote-exec" {
    inline = [
      "cloud-init status --wait",
    ]

    connection {
      host     = "${self.network_interface.0.addresses.0}"
      type     = "ssh"
      user     = "arch"
      #private_key = "${file("~/.ssh/id_rsa")}"
      private_key = "${file("./id_rsa")}"
    }
  }

  provisioner "local-exec" {
    command = "ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook -u arch -i ${self.network_interface.0.addresses.0}, --private-key ${var.private_key_path} provision.yml"
  }

}

terraform {
  required_version = ">= 0.12"
}

output "ips" {
  # show IP, run 'terraform refresh' if not populated
  value = libvirt_domain.domain-ubuntu.*.network_interface.0.addresses
}
