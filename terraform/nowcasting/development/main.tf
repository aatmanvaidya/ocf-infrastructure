/*====

This is the main main terraform code for the UK platform. It is used to deploy the platform to AWS.
It currently just has the GSP and National services

The componentes ares:
0.1 - Networking
0.2 - EC2 bastion
0.3 - S3 buckets
0.4 - ECS cluster
0.5 - PV ECS cluster
0.6 - S3 bucket for forecasters
0.7 - S3 bucket for PVsite ML models
1.1 - API
1.2 - sites API
2.1 - Database
2.2 - PVSite Database
2.3 - PVsite Database clean up
3.1 - NWP Consumer
3.2 - NWP National Consumer
3.3 - Satellite Consumer
3.4 - PV Consumer
3.5 - GSP Consumer (from PVLive)
4.1 - Metrics
4.2 - Forecast PVnet 1
4.3 - Forecast National XG
4.4 - Forecast PVnet 2
4.5 - Forecast Blend
4.6 - Forecast Site
5.1 - OCF Dashboard
5.2 - Airflow instance

Variables used across all modules
======*/
locals {
  production_availability_zones = ["${var.region}a", "${var.region}b", "${var.region}c"]
  domain = "nowcasting"
}


# 0.1.1
module "networking" {
  source = "../../modules/networking"

  region               = var.region
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  public_subnets_cidr  = var.public_subnets_cidr
  private_subnets_cidr = var.private_subnets_cidr
  availability_zones   = local.production_availability_zones
}

# 0.1.2
module "pvsite_subnetworking" {
  source = "../../modules/subnetworking"

  region                     = var.region
  environment                = var.environment
  vpc_id                     = module.networking.vpc_id
  public_subnets_cidr        = var.public_subnets_cidr
  private_subnets_cidr       = var.private_subnets_cidr
  availability_zones         = local.production_availability_zones
  domain                     = "pvsite"
  public_internet_gateway_id = module.networking.public_internet_gateway.id
}


# 0.2
module "ec2-bastion" {
  source = "../../modules/networking/ec2_bastion"

  region               = var.region
  vpc_id               = module.networking.vpc_id
  public_subnets_id    = module.networking.public_subnets[0].id
}

# 0.3
module "s3" {
  source = "../../modules/storage/s3-trio"

  region      = var.region
  environment = var.environment
}

# 0.4
module "ecs" {
  source = "../../modules/ecs"

  region      = var.region
  environment = var.environment
  domain = "nowcasting"
}

# 0.5
module "pvsite_ecs" {
  source = "../../modules/ecs"

  region      = var.region
  environment = var.environment
  domain      = "pvsite"
}

# 0.6
module "forecasting_models_bucket" {
  source = "../../modules/storage/s3-private"

  region              = var.region
  environment         = var.environment
  service_name        = "national-forecaster-models"
  domain              = "nowcasting"
  lifecycled_prefixes = []
}

# 0.7
module "pvsite_ml_bucket" {
  source = "../../modules/storage/s3-private"

  region              = var.region
  environment         = var.environment
  service_name        = "ml-models"
  domain              = "pvsite"
  lifecycled_prefixes = []
}


# 1.1
module "api" {
  source = "../../modules/services/api"

  region                              = var.region
  environment                         = var.environment
  vpc_id                              = module.networking.vpc_id
  subnets                             = module.networking.public_subnets
  docker_version                      = var.api_version
  database_forecast_secret_url        = module.database.forecast-database-secret-url
  database_pv_secret_url              = module.database.pv-database-secret-url
  iam-policy-rds-forecast-read-secret = module.database.iam-policy-forecast-db-read
  iam-policy-rds-pv-read-secret       = module.database.iam-policy-pv-db-read
  auth_domain                         = var.auth_domain
  auth_api_audience                   = var.auth_api_audience
  n_history_days                      = "2"
  adjust_limit                        = 2000.0
  sentry_dsn = var.sentry_dsn
}

# 1.2
module "pvsite_api" {
  source = "../../modules/services/api_pvsite"

  region                          = var.region
  environment                     = var.environment
  vpc_id                          = module.networking.vpc_id
  subnets                         = [module.pvsite_subnetworking.public_subnet.id]
  docker_version                  = var.pvsite_api_version
  domain                          = "pvsite"
  database_secret_url             = module.pvsite_database.secret-url
  database_secret_read_policy_arn = module.pvsite_database.secret-policy.arn
  sentry_dsn                      = var.sentry_dsn
  auth_api_audience               = var.auth_api_audience
  auth_domain                     = var.auth_domain
}


# 2.1
module "database" {
  source = "../../modules/storage/database-pair"

  region          = var.region
  environment     = var.environment
  db_subnet_group = module.networking.private_subnet_group
  vpc_id          = module.networking.vpc_id
}


# 2.2
module "pvsite_database" {
  source = "../../modules/storage/postgres"

  region             = var.region
  environment        = var.environment
  db_subnet_group    = module.pvsite_subnetworking.private_subnet_group
  vpc_id             = module.networking.vpc_id
  db_name            = "pvsite"
  rds_instance_class = "db.t3.small"
  allow_major_version_upgrade = true
}


# 2.3
module "database_clean_up" {
  source = "../../modules/services/database_clean_up"
    region      = var.region
  environment = var.environment
  app-name    = "database_clean_up"
  ecs_config  = {
    docker_image   = "openclimatefix/pvsite_database_cleanup"
    docker_version = var.database_cleanup_version
    memory_mb = 512
    cpu=256
  }
  rds_config = {
    database_secret_arn             = module.pvsite_database.secret.arn
    database_secret_read_policy_arn = module.pvsite_database.secret-policy.arn
  }
  scheduler_config = {
    subnet_ids      = [module.pvsite_subnetworking.public_subnet.id]
    ecs_cluster_arn = module.pvsite_ecs.ecs_cluster.arn
    cron_expression = "cron(0 0 * * ? *)" # Once a day at midnight
  }

}


# 3.1
module "nwp" {
  source = "../../modules/services/nwp"

  region                  = var.region
  environment             = var.environment
  iam-policy-s3-nwp-write = module.s3.iam-policy-s3-nwp-write
  ecs-cluster             = module.ecs.ecs_cluster
  public_subnet_ids       = [module.networking.public_subnets[0].id]
  docker_version          = var.nwp_version
  database_secret         = module.database.forecast-database-secret
  iam-policy-rds-read-secret = module.database.iam-policy-forecast-db-read
  consumer-name = "nwp"
  s3_config = {
    bucket_id = module.s3.s3-nwp-bucket.id
  }
  command = [
      "download",
      "--source=metoffice",
      "--sink=s3",
      "--rdir=raw",
      "--zdir=data",
      "--create-latest"
  ]
}

# 3.2
module "nwp-national" {
  source = "../../modules/services/nwp"

  region                  = var.region
  environment             = var.environment
  iam-policy-s3-nwp-write = module.s3.iam-policy-s3-nwp-write
  ecs-cluster             = module.ecs.ecs_cluster
  public_subnet_ids       = [module.networking.public_subnets[0].id]
  docker_version          = var.nwp_version
  database_secret         = module.database.forecast-database-secret
  iam-policy-rds-read-secret = module.database.iam-policy-forecast-db-read
  consumer-name = "nwp-national"
  s3_config = {
    bucket_id = module.s3.s3-nwp-bucket.id
  }
  command = [
      "download",
      "--source=metoffice",
      "--sink=s3",
      "--rdir=raw-national",
      "--zdir=data-national",
      "--create-latest"
  ]
}

# 3.3 Sat Consumer
module "sat" {
  source = "../../modules/services/sat"

  region                  = var.region
  environment             = var.environment
  iam-policy-s3-sat-write = module.s3.iam-policy-s3-sat-write
  s3-bucket               = module.s3.s3-sat-bucket
  ecs-cluster             = module.ecs.ecs_cluster
  public_subnet_ids       = [module.networking.public_subnets[0].id]
  docker_version          = var.sat_version
  database_secret         = module.database.forecast-database-secret
  iam-policy-rds-read-secret = module.database.iam-policy-forecast-db-read
}

# 3.4
module "pv" {
  source = "../../modules/services/pv"

  region                  = var.region
  environment             = var.environment
  ecs-cluster             = module.ecs.ecs_cluster
  public_subnet_ids       = [module.networking.public_subnets[0].id]
  database_secret         = module.database.pv-database-secret
  database_secret_forecast = module.database.forecast-database-secret
  docker_version          = var.pv_version
  docker_version_ss          = var.pv_ss_version
  iam-policy-rds-read-secret = module.database.iam-policy-pv-db-read
  iam-policy-rds-read-secret_forecast = module.database.iam-policy-forecast-db-read
}

# 3.4
module "gsp" {
  source = "../../modules/services/gsp"

  region                  = var.region
  environment             = var.environment
  ecs-cluster             = module.ecs.ecs_cluster
  public_subnet_ids       = [module.networking.public_subnets[0].id]
  database_secret         = module.database.forecast-database-secret
  docker_version          = var.gsp_version
  iam-policy-rds-read-secret = module.database.iam-policy-forecast-db-read
}

# 4.1
module "metrics" {
  source = "../../modules/services/metrics"

  region                  = var.region
  environment             = var.environment
  ecs-cluster             = module.ecs.ecs_cluster
  public_subnet_ids       = [module.networking.public_subnets[0].id]
  database_secret         = module.database.forecast-database-secret
  docker_version          = var.metrics_version
  iam-policy-rds-read-secret = module.database.iam-policy-forecast-db-read
  use_pvnet_gsp_sum = "true"
}

# 4.2
module "forecast" {
  source = "../../modules/services/forecast"

  region                        = var.region
  environment                   = var.environment
  ecs-cluster                   = module.ecs.ecs_cluster
  subnet_ids                    = [module.networking.public_subnets[0].id]
  iam-policy-rds-read-secret    = module.database.iam-policy-forecast-db-read
  iam-policy-rds-pv-read-secret = module.database.iam-policy-pv-db-read
  iam-policy-s3-nwp-read        = module.s3.iam-policy-s3-nwp-read
  iam-policy-s3-sat-read        = module.s3.iam-policy-s3-sat-read
  iam-policy-s3-ml-read         = module.s3.iam-policy-s3-ml-write #TODO update name
  database_secret               = module.database.forecast-database-secret
  pv_database_secret            = module.database.pv-database-secret
  docker_version                = var.forecast_version
  s3-nwp-bucket                 = module.s3.s3-nwp-bucket
  s3-sat-bucket                 = module.s3.s3-sat-bucket
  s3-ml-bucket                  = module.s3.s3-ml-bucket
}

# 4.3
module "national_forecast" {
  source = "../../modules/services/forecast_generic"

  region      = var.region
  environment = var.environment
  app-name    = "forecast_national"
  ecs_config  = {
    docker_image   = "openclimatefix/gradboost_pv"
    docker_version = var.national_forecast_version
    memory_mb = 11264
    cpu = 2048
  }
  rds_config = {
    database_secret_arn             = module.database.forecast-database-secret.arn
    database_secret_read_policy_arn = module.database.iam-policy-forecast-db-read.arn
  }
  scheduler_config = {
    subnet_ids      = [module.networking.public_subnets[0].id]
    ecs_cluster_arn = module.ecs.ecs_cluster.arn
    cron_expression = "cron(15 0 * * ? *)" # Runs at 00.15, airflow does the rest
  }
  s3_ml_bucket = {
    bucket_id              = module.forecasting_models_bucket.bucket.id
    bucket_read_policy_arn = module.forecasting_models_bucket.read-policy.arn
  }
  s3_nwp_bucket = {
    bucket_id = module.s3.s3-nwp-bucket.id
    bucket_read_policy_arn = module.s3.iam-policy-s3-nwp-read.arn
    datadir = "data-national"
  }
}

# 4.4
module "forecast_pvnet" {
  source = "../../modules/services/forecast_generic"

  region      = var.region
  environment = var.environment
  app-name    = "forecast_pvnet"
  ecs_config  = {
    docker_image   = "openclimatefix/pvnet_app"
    docker_version = var.forecast_pvnet_version
    memory_mb = 8192
    cpu = 2048
  }
  rds_config = {
    database_secret_arn             = module.database.forecast-database-secret.arn
    database_secret_read_policy_arn = module.database.iam-policy-forecast-db-read.arn
  }
  scheduler_config = {
    subnet_ids      = [module.networking.public_subnets[0].id]
    ecs_cluster_arn = module.ecs.ecs_cluster.arn
    cron_expression = "cron(15 0 * * ? *)" # Runs at 00.15, airflow does the rest
  }
  s3_ml_bucket = {
    bucket_id              = module.forecasting_models_bucket.bucket.id
    bucket_read_policy_arn = module.forecasting_models_bucket.read-policy.arn
  }
  s3_nwp_bucket = {
    bucket_id = module.s3.s3-nwp-bucket.id
    bucket_read_policy_arn = module.s3.iam-policy-s3-nwp-read.arn
    datadir = "data-national"
  }
  s3_satellite_bucket = {
    bucket_id = module.s3.s3-sat-bucket.id
    bucket_read_policy_arn = module.s3.iam-policy-s3-sat-read.arn
    datadir = "data/latest"
  }
  loglevel= "INFO"
  pvnet_gsp_sum = "true"
}

# 5.1
module "analysis_dashboard" {
    source = "../../modules/services/internal_ui"

    region      = var.region
    environment = var.environment
    eb_app_name = "internal-ui"
    domain = "nowcasting"
    docker_config = {
        image = "ghcr.io/openclimatefix/uk-analysis-dashboard"
        version = var.internal_ui_version
    }
    networking_config = {
        vpc_id = module.networking.vpc_id
        subnets = [module.networking.public_subnets[0].id]
    }
    database_config = {
        secret = module.database.forecast-database-secret-url
        read_policy_arn = module.database.iam-policy-forecast-db-read.arn
    }
    auth_config = {
        auth0_domain = var.auth_domain
        auth0_client_id = var.auth_dashboard_client_id
    }
    show_pvnet_gsp_sum = "true"
}

# 4.5
module "forecast_blend" {
  source = "../../modules/services/forecast_blend"

  region      = var.region
  environment = var.environment
  app-name    = "forecast_blend"
  ecs_config  = {
    docker_image   = "openclimatefix/uk_pv_forecast_blend"
    docker_version = var.forecast_blend_version
    memory_mb = 1024
    cpu = 512
  }
  rds_config = {
    database_secret_arn             = module.database.forecast-database-secret.arn
    database_secret_read_policy_arn = module.database.iam-policy-forecast-db-read.arn
  }
  loglevel= "INFO"

}

# 5.2
module "airflow" {
  source = "../../modules/services/airflow"

  environment   = var.environment
  vpc_id        = module.networking.vpc_id
  subnets       = [module.networking.public_subnets[0].id]
  db_url        = module.database.forecast-database-secret-airflow-url
  docker-compose-version       = "0.0.3"
  ecs_subnet=module.networking.public_subnets[0].id
  ecs_security_group=var.ecs_security_group # TODO should be able to update this to use the module
}


# 4.6
module "pvsite_forecast" {
  source = "../../modules/services/forecast_generic"

  region      = var.region
  environment = var.environment
  app-name    = "pvsite_forecast"
  ecs_config  = {
    docker_image   = "openclimatefix/pvsite_forecast"
    docker_version = var.pvsite_forecast_version
    memory_mb = 4096
    cpu=1024
  }
  rds_config = {
    database_secret_arn             = module.pvsite_database.secret.arn
    database_secret_read_policy_arn = module.pvsite_database.secret-policy.arn
  }
  scheduler_config = {
    subnet_ids      = [module.pvsite_subnetworking.public_subnet.id]
    ecs_cluster_arn = module.pvsite_ecs.ecs_cluster.arn
    cron_expression = "cron(*/15 * * * ? *)" # Every 15 minutes
  }
  s3_ml_bucket = {
    bucket_id              = module.pvsite_ml_bucket.bucket.id
    bucket_read_policy_arn = module.pvsite_ml_bucket.read-policy.arn
  }
  s3_nwp_bucket = var.nwp_bucket_config
}
