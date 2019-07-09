locals {
  nodes_cidr_block = var.cidr_block
  api_vip = cidrhost(local.nodes_cidr_block, 5)
  dns_vip = cidrhost(local.nodes_cidr_block, 6)
  # TODO(mandre) add VIP for ingress
}


data "openstack_networking_network_v2" "external_network" {
  name       = var.external_network
  network_id = var.external_network_id
  external   = true
}

resource "openstack_networking_network_v2" "openshift-private" {
  name           = "${var.cluster_id}-openshift"
  admin_state_up = "true"
  # FIXME(mandre) why is it not taking my updated provider into account?
  # dns_domain     = var.cluster_domain
  tags           = ["openshiftClusterID=${var.cluster_id}"]
}

resource "openstack_networking_subnet_v2" "nodes" {
  name            = "${var.cluster_id}-nodes"
  cidr            = local.nodes_cidr_block
  ip_version      = 4
  network_id      = openstack_networking_network_v2.openshift-private.id
  tags            = ["openshiftClusterID=${var.cluster_id}"]
  allocation_pool {
    start = cidrhost(local.nodes_cidr_block, 10)
    # FIXME(mandre) this should be the last available IP of the CIDR
    end   = cidrhost(local.nodes_cidr_block, 50)
  }
  dns_nameservers = var.bootstrap_dns ? [] : [local.dns_vip]
  # TODO(mandre) should we just set it to a VIP right now? If so, we don't need
  # the bootstrap_dns var.
  # I think we can't because the bootstrap node won't be able to get to swift
  # in order to retrieve ignition file. This needs to be tested...
  # We're setting the bootstrap DNS to the DNS VIP via the ignition file anyway
  # We could consider serve the bootstrap ignition via IP, but meh...
}

# TODO(mandre) Do we need to create a port for the VIP?
# resource "openstack_networking_port_v2" "api_vip" {
#   name  = "${var.cluster_id}-api-vip-port"
#   admin_state_up     = "true"
#   network_id         = openstack_networking_network_v2.openshift-private.id
#   security_group_ids = [openstack_networking_secgroup_v2.master.id]
#   tags               = ["openshiftClusterID=${var.cluster_id}"]

#   fixed_ip {
#     subnet_id = openstack_networking_subnet_v2.nodes.id
#     ip_address = local.api_vip
#   }
# }

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

  allowed_address_pairs {
    ip_address = local.api_vip
  }
  allowed_address_pairs {
    ip_address = local.dns_vip
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

  allowed_address_pairs {
    ip_address = local.api_vip
  }
}

resource "openstack_networking_floatingip_associate_v2" "api_fip" {
  count       = length(var.lb_floating_ip) == 0 ? 0 : 1
  # NOTE(mandre) Is this OK to not have HA for external access via the FIP?
  # FIP must point to a master node, otherwise the installer won't know when
  # bootstrap node has completed
  port_id     = openstack_networking_port_v2.masters[0].id
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

