data "openstack_images_image_v2" "masters_img" {
  name        = var.base_image
  most_recent = true
}

data "openstack_compute_flavor_v2" "masters_flavor" {
  name = var.flavor_name
}

data "ignition_file" "hostname" {
  count      = var.instance_count
  filesystem = "root"
  mode       = "420" // 0644
  path       = "/etc/hostname"

  content {
    content = <<EOF
master-${count.index}
EOF

  }
}

data "ignition_file" "hosts" {
  filesystem = "root"
  mode = "420" // 0644
  path = "/etc/hosts"

  content {
    content = <<EOF
${var.bootstrap_ip} api-int.${var.cluster_domain} api.${var.cluster_domain}
EOF

  }
}

data "ignition_config" "master_ignition_config" {
  count = var.instance_count

  append {
    source = "data:text/plain;charset=utf-8;base64,${base64encode(var.user_data_ign)}"
  }

  files = [
    element(data.ignition_file.hostname.*.id, count.index),
    data.ignition_file.haproxy_watcher_script.id,
    data.ignition_file.hosts.id,
  ]

  systemd = [
    data.ignition_systemd_unit.haproxy_unit.id,
    data.ignition_systemd_unit.haproxy_unit_watcher.id,
    data.ignition_systemd_unit.haproxy_timer_watcher.id,
  ]
}

data "ignition_systemd_unit" "haproxy_unit" {
  name    = "haproxy.service"
  enabled = true

  content = <<EOF
[Unit]
Description=Load balancer for the OpenShift services
[Service]
ExecStartPre=/sbin/setenforce 0
ExecStart=/bin/podman run --rm -ti --net=host -v /etc/haproxy:/usr/local/etc/haproxy:ro docker.io/library/haproxy:1.7
ExecStop=/bin/podman stop -t 10 haproxy
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF

}

data "ignition_systemd_unit" "haproxy_unit_watcher" {
  name = "haproxy-watcher.service"
  enabled = true

  content = <<EOF
[Unit]
Description=HAproxy config updater
[Service]
Type=oneshot
ExecStart=/usr/local/bin/haproxy-watcher.sh
[Install]
WantedBy=multi-user.target
EOF

  }

  data "ignition_systemd_unit" "haproxy_timer_watcher" {
    name    = "haproxy-watcher.timer"
    enabled = true

    content = <<EOF
[Timer]
OnCalendar=*:0/2
[Install]
WantedBy=timers.target
EOF

  }

  data "ignition_file" "haproxy_watcher_script" {
    filesystem = "root"
    mode = "489" // 0755
    path = "/usr/local/bin/haproxy-watcher.sh"

    content {
      content = <<TFEOF
#!/bin/bash
set -x
# NOTE(flaper87): We're doing this here for now
# because our current vendored verison for terraform
# doesn't support appending to an ignition_file. This
# is coming in 2.3
mkdir -p /etc/haproxy
export KUBECONFIG=/var/lib/kubelet/kubeconfig
TEMPLATE="{{range .items}}{{\$addresses:=.status.addresses}}{{range .status.conditions}}{{if eq .type \"Ready\"}}{{if eq .status \"True\" }}{{range \$addresses}}{{if eq .type \"InternalIP\"}}{{.address}}{{end}}{{end}}{{end}}{{end}}{{end}} {{end}}"
MASTERS=$(oc get nodes -l node-role.kubernetes.io/master -ogo-template="$TEMPLATE")
WORKERS=$(oc get nodes -l node-role.kubernetes.io/worker -ogo-template="$TEMPLATE")
update_cfg_and_restart() {
    CHANGED=$(diff /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.new)
    if [[ ! -f /etc/haproxy/haproxy.cfg ]] || [[ ! $CHANGED -eq "" ]];
    then
        cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup || true
        cp /etc/haproxy/haproxy.cfg.new /etc/haproxy/haproxy.cfg
        systemctl restart haproxy
    fi
}
if [[ $MASTERS -eq "" ]];
then
cat > /etc/haproxy/haproxy.cfg.new << EOF
listen ${var.cluster_id}-api-masters
    bind 0.0.0.0:6443
    bind 0.0.0.0:22623
    mode tcp
    balance roundrobin
    server bootstrap-22623 ${var.bootstrap_ip} check port 22623
    server bootstrap-6443 ${var.bootstrap_ip} check port 6443
    ${replace(join("\n    ", formatlist("server master-%s %s check port 6443", var.master_port_names, var.master_ips)), "master-port-", "")}
EOF
    update_cfg_and_restart
    exit 0
fi
for master in $MASTERS;
do
    MASTER_LINES="$MASTER_LINES
    server $master $master check port 6443"
done
for worker in $WORKERS;
do
    WORKER_LINES="$WORKER_LINES
    server $worker $worker check port 443"
done
cat > /etc/haproxy/haproxy.cfg.new << EOF
listen ${var.cluster_id}-api-masters
    bind 0.0.0.0:6443
    bind 0.0.0.0:22623
    mode tcp
    balance roundrobin$MASTER_LINES
listen ${var.cluster_id}-api-workers
    bind 0.0.0.0:80
    bind 0.0.0.0:443
    mode tcp
    balance roundrobin$WORKER_LINES
EOF
update_cfg_and_restart
TFEOF

}
}

resource "openstack_compute_instance_v2" "master_conf" {
  name  = "${var.cluster_id}-master-${count.index}"
  count = var.instance_count

  flavor_id       = data.openstack_compute_flavor_v2.masters_flavor.id
  image_id        = data.openstack_images_image_v2.masters_img.id
  security_groups = var.master_sg_ids
  user_data = element(
    data.ignition_config.master_ignition_config.*.rendered,
    count.index,
  )

  network {
    port = var.master_port_ids[count.index]
  }

  metadata = {
    Name = "${var.cluster_id}-master"
    # "kubernetes.io/cluster/${var.cluster_id}" = "owned"
    openshiftClusterID = var.cluster_id
  }
}

