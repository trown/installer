variable "base_image" {
  type = string
}

variable "cluster_id" {
  type        = string
  description = "The identifier for the cluster."
}

variable "cluster_domain" {
  type        = string
  description = "The domain name of the cluster. All DNS records must be under this domain."
}

variable "flavor_name" {
  type = string
}

variable "instance_count" {
  type = string
}

variable "master_sg_ids" {
  type        = list(string)
  default     = ["default"]
  description = "The security group IDs to be applied to the master nodes."
}

variable "master_port_ids" {
  type        = list(string)
  description = "List of port ids for the master nodes"
}

variable "user_data_ign" {
  type = string
}

variable "api_vip" {
  type = string
}

variable "dns_vip" {
  type = string
}

variable "master_ips" {
  type = list(string)
}

variable "bootstrap_ip" {
  type = string
}
