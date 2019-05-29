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
    data.ignition_file.corefile.id,
    data.ignition_file.coredb.id,
    data.ignition_file.hosts.id,

  ]

  systemd = [
    data.ignition_systemd_unit.local_dns.id,
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

data "ignition_file" "hosts" {
  filesystem = "root"
  mode       = "420" // 0644
  path       = "/etc/hosts"

  content {
    content = <<EOF
${var.bootstrap_ip} api-int.${var.cluster_domain} api.${var.cluster_domain}
EOF
  }
}

data "ignition_file" "corefile" {
  filesystem = "root"
  mode = "420" // 0644
  path = "/etc/coredns/Corefile"

  content {
    content = <<EOF
. {
    log
    errors
    reload 10s
    forward . /etc/resolv.conf {
    }
}
${var.cluster_domain} {
    log
    errors
    reload 10s
    file /etc/coredns/db.${var.cluster_domain} {
        upstream /etc/resolv.conf
    }
}
EOF

  }
}

data "ignition_file" "coredb" {
  filesystem = "root"
  mode       = "420" // 0644
  path       = "/etc/coredns/db.${var.cluster_domain}"

  content {
    content = <<EOF
$ORIGIN ${var.cluster_domain}.
@    3600 IN SOA host.${var.cluster_domain}. hostmaster (
                                2017042752 ; serial
                                7200       ; refresh (2 hours)
                                3600       ; retry (1 hour)
                                1209600    ; expire (2 weeks)
                                3600       ; minimum (1 hour)
                                )
api  IN  A  ${var.lb_floating_ip}
api-int  IN  A  ${var.bootstrap_ip}
bootstrap.${var.cluster_domain}  IN  A  ${var.bootstrap_ip}
EOF

  }
}

data "ignition_systemd_unit" "local_dns" {
  name = "local-dns.service"

  content = <<EOF
[Unit]
Description=Internal DNS serving the required OpenShift records
[Service]
ExecStart=/bin/podman run --rm -i -t -m 128m --net host --cap-add=NET_ADMIN -v /etc/coredns:/etc/coredns:Z openshift/origin-coredns:v4.0 -conf /etc/coredns/Corefile
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

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

