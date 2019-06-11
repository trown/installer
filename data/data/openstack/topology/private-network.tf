locals {
  # masters_cidr_block   = cidrsubnet(var.cidr_block, 2, 0)
  # workers_cidr_block   = cidrsubnet(var.cidr_block, 2, 1)
  # bootstrap_cidr_block = cidrsubnet(var.cidr_block, 2, 2)
  nodes_cidr_block = var.cidr_block
}


data "openstack_networking_network_v2" "external_network" {
  name       = var.external_network
  network_id = var.external_network_id
  external   = true
}

resource "openstack_networking_network_v2" "openshift-private" {
  name           = "${var.cluster_id}-openshift"
  admin_state_up = "true"
  # NOTE(mandre) after updating the openstack terraform provider to v1.17.0 or
  # above we should be able to configure the neutron dhcp server this way
  # dns_domain     = var.cluster_domain
  tags           = ["openshiftClusterID=${var.cluster_id}"]
}

# resource "openstack_networking_subnet_v2" "bootstrap" {
#   name       = "${var.cluster_id}-bootstrap"
#   cidr       = local.bootstrap_cidr_block
#   ip_version = 4
#   network_id = openstack_networking_network_v2.openshift-private.id
#   tags       = ["openshiftClusterID=${var.cluster_id}"]
# }

# NOTE(mandre) This subnet only serves for the masters created when the initial
# cluster is brought up. Subsequent masters will be placed by MCO on the nodes
# subnet
# resource "openstack_networking_subnet_v2" "masters" {
#   name            = "${var.cluster_id}-masters"
#   cidr            = local.initial_masters_cidr_block
#   ip_version      = 4
#   network_id      = openstack_networking_network_v2.openshift-private.id
#   tags            = ["openshiftClusterID=${var.cluster_id}"]
#   # dns_nameservers = var.bootstrap_dns ? [openstack_networking_port_v2.bootstrap_port.all_fixed_ips[0]] : []
#   dns_nameservers = [openstack_networking_port_v2.bootstrap_port.all_fixed_ips[0]]
# }

resource "openstack_networking_subnet_v2" "nodes" {
  name            = "${var.cluster_id}-nodes"
  cidr            = local.nodes_cidr_block
  ip_version      = 4
  network_id      = openstack_networking_network_v2.openshift-private.id
  tags            = ["openshiftClusterID=${var.cluster_id}"]
  # FIXME(mandre) This only takes into account the initial master nodes and not
  # the ones that came after the initial deployment
  # dns_nameservers = flatten(openstack_networking_port_v2.masters.*.all_fixed_ips)
  # NOTE(mandre) Make DNS setting via Ignition
}

resource "openstack_networking_port_v2" "masters" {
  name  = "${var.cluster_id}-master-port-${count.index}"
  count = var.masters_count

  admin_state_up     = "true"
  network_id         = openstack_networking_network_v2.openshift-private.id
  security_group_ids = [openstack_networking_secgroup_v2.master.id]
  tags               = ["openshiftClusterID=${var.cluster_id}"]

  extra_dhcp_option {
    name = "domain-search"
    value = var.cluster_domain
  }

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.nodes.id
  }
}

resource "openstack_networking_trunk_v2" "masters" {
  name  = "${var.cluster_id}-master-trunk-${count.index}"
  count = var.trunk_support ? var.masters_count : 0
  tags  = ["openshiftClusterID=${var.cluster_id}"]

  admin_state_up = "true"
  port_id        = openstack_networking_port_v2.masters[count.index].id
}

resource "openstack_networking_port_v2" "bootstrap_port" {
  name = "${var.cluster_id}-bootstrap-port"

  admin_state_up     = "true"
  network_id         = openstack_networking_network_v2.openshift-private.id
  security_group_ids = [openstack_networking_secgroup_v2.master.id]
  tags               = ["openshiftClusterID=${var.cluster_id}"]
  extra_dhcp_option {
    name = "domain-search"
    value = var.cluster_domain
  }

  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.nodes.id
  }
}

resource "openstack_networking_floatingip_associate_v2" "api_fip" {
  count       = length(var.lb_floating_ip) == 0 ? 0 : 1
  port_id     = var.bootstrap_dns ? openstack_networking_port_v2.bootstrap_port.id : openstack_networking_port_v2.masters[0].id
  floating_ip = var.lb_floating_ip
}

resource "openstack_networking_router_v2" "openshift-external-router" {
  name                = "${var.cluster_id}-external-router"
  admin_state_up      = true
  external_network_id = data.openstack_networking_network_v2.external_network.id
  tags                = ["openshiftClusterID=${var.cluster_id}"]
}

resource "openstack_networking_router_interface_v2" "nodes_router_interface" {
  router_id = openstack_networking_router_v2.openshift-external-router.id
  subnet_id = openstack_networking_subnet_v2.nodes.id
}

