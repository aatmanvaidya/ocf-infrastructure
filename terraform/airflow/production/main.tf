/*====
Variables used across all modules
======*/
locals {
  production_availability_zones = ["${var.region}a", "${var.region}b", "${var.region}c"]
  domain = "airflow"
}




module "airflow_subnetworking" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/subnetworking?ref=84db064"


  region                     = var.region
  environment                = var.environment
  vpc_id                     = var.vpc_id
  public_subnets_cidr        = var.public_subnets_cidr
  private_subnets_cidr       = var.private_subnets_cidr
  availability_zones         = local.production_availability_zones
  domain                     = local.domain
  public_internet_gateway_id = var.public_internet_gateway_id
}

