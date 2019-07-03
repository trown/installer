resource "openstack_objectstorage_object_v1" "ignition" {
  container_name = var.swift_container
  name           = "bootstrap.ign"
  content        = var.ignition
}

resource "openstack_objectstorage_tempurl_v1" "ignition_tmpurl" {
  container = var.swift_container
  method    = "get"
  object    = openstack_objectstorage_object_v1.ignition.name
  ttl       = 3600
}

data "ignition_config" "redirect" {
  append {
    source = openstack_objectstorage_tempurl_v1.ignition_tmpurl.url
  }

  files = [
    data.ignition_file.hostname.id,
    data.ignition_file.dns_conf.id,
    data.ignition_file.dhcp_conf.id,
    data.ignition_file.switch_api_endpoint.id,
  ]

  systemd = [
    data.ignition_systemd_unit.switch_api_endpoint.id,
  ]
}

data "ignition_file" "dhcp_conf" {
  filesystem = "root"
  mode       = "420"
  path       = "/etc/NetworkManager/conf.d/dhcp-client.conf"

  content {
    content = <<EOF
[main]
dhcp=dhclient
EOF
  }
}

data "ignition_file" "dns_conf" {
  filesystem = "root"
  mode = "420"
  path = "/etc/dhcp/dhclient.conf"

  content {
    content = <<EOF
send dhcp-client-identifier = hardware;
prepend domain-name-servers ${var.master_vm_fixed_ip};
EOF

  }
}

data "ignition_file" "hostname" {
  filesystem = "root"
  mode       = "420" // 0644
  path       = "/etc/hostname"

  content {
    content = <<EOF
bootstrap
EOF

  }
}

data "ignition_file" "switch_api_endpoint" {
  filesystem = "root"
  mode       = "493" // 0755
  path       = "/usr/local/bin/switch-api-endpoint.sh"

  content {
    content = <<EOF
#!/usr/bin/env bash

set -eu

wait_for_existence() {
	while [ ! -e "$${1}" ]
	do
		sleep 5
	done
}

echo "Waiting for bootstrap to complete..."
wait_for_existence /opt/openshift/.bootkube.done
wait_for_existence /opt/openshift/.openshift.done

echo "Switching bootstrap's API address to a master node"
echo "${var.master_vm_fixed_ip} api-int.${var.cluster_domain} api.${var.cluster_domain}" >> /etc/hosts
EOF

  }
}

data "ignition_systemd_unit" "switch_api_endpoint" {
  name    = "switch-api-endpoint.service"
  enabled = true

  content = <<EOF
[Unit]
Description=Switch the bootstrap API to a master node. This will enable `progress.service` to send the boostrap-complete event.
# Workaround for https://github.com/systemd/systemd/issues/1312
Wants=bootkube.service openshift.service
After=bootkube.service openshift.service

[Service]
ExecStart=/usr/local/bin/switch-api-endpoint.sh

Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
}


data "openstack_images_image_v2" "bootstrap_image" {
  name = var.image_name
  most_recent = true
}

data "openstack_compute_flavor_v2" "bootstrap_flavor" {
  name = var.flavor_name
}

resource "openstack_compute_instance_v2" "bootstrap" {
  name = "${var.cluster_id}-bootstrap"
  flavor_id = data.openstack_compute_flavor_v2.bootstrap_flavor.id
  image_id = data.openstack_images_image_v2.bootstrap_image.id

  user_data = data.ignition_config.redirect.rendered

  network {
    port = var.bootstrap_port_id
  }

  metadata = {
    Name = "${var.cluster_id}-bootstrap"
    # "kubernetes.io/cluster/${var.cluster_id}" = "owned"
    openshiftClusterID = var.cluster_id
  }
}

