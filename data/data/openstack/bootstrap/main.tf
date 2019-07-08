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
    data.ignition_file.hosts.id,
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

  # FIXME(mandre) this should really be a VIP for the DNS
  # Also this will likely cause delay with bootstrap node networking until the
  # master come up and are able to serve DNS queries.
  # Not sure the bootstrap is trying to resolve anything it doesn't have in its
  # hosts file...
  content {
    content = <<EOF
send dhcp-client-identifier = hardware;
prepend domain-name-servers ${var.api_vip};
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

data "ignition_file" "hosts" {
  filesystem = "root"
  mode       = "420" // 0644
  path       = "/etc/hosts"

  content {
    content = <<EOF
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
${var.api_vip} api-int.${var.cluster_domain} api.${var.cluster_domain}
EOF
  }
}

data "openstack_images_image_v2" "bootstrap_image" {
  name = var.image_name
  most_recent = true
}

data "openstack_compute_flavor_v2" "bootstrap_flavor" {
  name = var.flavor_name
}

resource "openstack_compute_instance_v2" "bootstrap" {
  name      = "${var.cluster_id}-bootstrap"
  flavor_id = data.openstack_compute_flavor_v2.bootstrap_flavor.id
  image_id  = data.openstack_images_image_v2.bootstrap_image.id

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
