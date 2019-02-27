data "openstack_images_image_v2" "masters_img" {
  name        = "${var.base_image}"
  most_recent = true
}

data "openstack_compute_flavor_v2" "masters_flavor" {
  name = "${var.flavor_name}"
}

data "ignition_config" "master_ignition_config" {
  append {
    source = "data:text/plain;charset=utf-8;base64,${base64encode(var.user_data_ign)}"
  }
}

resource "openstack_blockstorage_volume_v2" "masters_vols" {
  name     = "${var.cluster_id}-master-${count.index}"
  count    = "${var.instance_count}"
  size     = 20
  image_id = "${data.openstack_images_image_v2.masters_img.id}"

  metadata {
    Name = "${var.cluster_id}-master-vol"

    openshiftClusterID = "${var.cluster_id}"
  }
}

resource "openstack_compute_instance_v2" "master_conf" {
  name  = "${var.cluster_id}-master-${count.index}"
  count = "${var.instance_count}"

  flavor_id       = "${data.openstack_compute_flavor_v2.masters_flavor.id}"
  security_groups = ["${var.master_sg_ids}"]
  user_data       = "${data.ignition_config.master_ignition_config.rendered}"
#  image_id        = "${data.openstack_images_image_v2.masters_img.id}"

  network = {
    port = "${var.master_port_ids[count.index]}"
  }

  block_device {
    uuid                  =  "${openstack_blockstorage_volume_v2.masters_vols.*.id[count.index]}"
    source_type           = "volume"
    boot_index            = 0
    destination_type      = "volume"
    delete_on_termination = true
  }

  metadata {
    Name = "${var.cluster_id}-master"

    # "kubernetes.io/cluster/${var.cluster_id}" = "owned"
    openshiftClusterID = "${var.cluster_id}"
  }
}
