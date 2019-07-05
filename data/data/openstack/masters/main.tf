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

# FIXME(mandre) stop hardcoding the number of master nodes
data "ignition_file" "clustervars" {
  filesystem = "root"
  mode       = "420" // 0644
  path       = "/etc/kubernetes/static-pod-resources/clustervars"

  content {
    content = <<EOF
export FLOATING_IP=${var.lb_floating_ip}
export BOOTSTRAP_IP=${var.bootstrap_ip}
export MASTER_FIXED_IPS_0=${var.master_ips[0]}
export MASTER_FIXED_IPS_1=${var.master_ips[1]}
export MASTER_FIXED_IPS_2=${var.master_ips[2]}
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
    data.ignition_file.clustervars.id,
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
    if [[ ! -f /etc/haproxy/haproxy.cfg ]] || [[ ! -z "$CHANGED" ]];
    then
        cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup || true
        cp /etc/haproxy/haproxy.cfg.new /etc/haproxy/haproxy.cfg
        systemctl restart haproxy
    fi
}

lb_port="7443"
api_port="6443"
rules=$(iptables -L PREROUTING -n -t nat --line-numbers | awk '/OCP_API_LB_REDIRECT/ {print $1}'  | tac)
if [[ -z "$rules" ]]; then
    # FIXME(mandre) Get the cluster CIDR block from the installer
    # This would be even better to put this rule directly in terraform or ignition
    iptables -t nat -I PREROUTING ! --src 172.30.0.0/16 --dst 0/0 -p tcp --dport "$api_port" -j REDIRECT --to-ports "$lb_port" -m comment --comment "OCP_API_LB_REDIRECT"
fi

# FIXME(mandre) we shouldn't need to add boostrap node here
# This should fix the back and forth between bootstrap and prod control plane
if [[ -z "$MASTERS" ]];
then
cat > /etc/haproxy/haproxy.cfg.new << EOF
listen ${var.cluster_id}-api-masters
    bind 0.0.0.0:7443
    mode tcp
    balance roundrobin
    server bootstrap-6443 ${var.bootstrap_ip} check port 6443
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
    bind 0.0.0.0:7443
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
    # FIXME(mandre) shouldn't it be "${var.cluster_id}-master-${count.index}" ?
    Name = "${var.cluster_id}-master"
    # "kubernetes.io/cluster/${var.cluster_id}" = "owned"
    openshiftClusterID = var.cluster_id
  }
}

