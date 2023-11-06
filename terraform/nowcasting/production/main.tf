/*====
Variables used across all modules
======*/
locals {
  production_availability_zones = ["${var.region}a", "${var.region}b", "${var.region}c"]
  domain = "nowcasting"
  modules_url = "github.com/openclimatefix/ocf-infrastructure//terraform/modules"
}


module "networking" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/networking?ref=85d7572"
  region               = var.region
  environment          = var.environment
  vpc_cidr             = var.vpc_cidr
  public_subnets_cidr  = var.public_subnets_cidr
  private_subnets_cidr = var.private_subnets_cidr
  availability_zones   = local.production_availability_zones
}

module "ec2-bastion" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/networking/ec2_bastion?ref=85d7572"

  region               = var.region
  vpc_id               = module.networking.vpc_id
  public_subnets_id    = module.networking.public_subnets[0].id
}

module "s3" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/storage/s3-trio?ref=1ef6d13"

  region      = var.region
  environment = var.environment

}

module "ecs" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/ecs?ref=85d7572"
  region      = var.region
  environment = var.environment
  domain = local.domain
}

module "forecasting_models_bucket" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/storage/s3-private?ref=85d7572"

  region              = var.region
  environment         = var.environment
  service_name        = "national-forecaster-models"
  domain              = local.domain
  lifecycled_prefixes = []
}

module "api" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/services/api?ref=b6ac5d2"

  region                              = var.region
  environment                         = var.environment
  vpc_id                              = module.networking.vpc_id
  subnets                             = module.networking.public_subnets
  docker_version                      = var.api_version
  database_forecast_secret_url        = module.database.forecast-database-secret-url
  database_pv_secret_url              = module.database.pv-database-secret-url
  iam-policy-rds-forecast-read-secret = module.database.iam-policy-forecast-db-read
  iam-policy-rds-pv-read-secret       = module.database.iam-policy-pv-db-read
  auth_domain = var.auth_domain
  auth_api_audience = var.auth_api_audience
  n_history_days = "2"
  adjust_limit = 1000.0
  sentry_dsn = var.sentry_dsn
}


module "database" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/storage/database-pair?ref=47dc829"

  region          = var.region
  environment     = var.environment
  db_subnet_group = module.networking.private_subnet_group
  vpc_id          = module.networking.vpc_id
}

module "nwp" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/services/nwp?ref=e23dda0"

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
    savedir_data = "data"
    savedir_raw = "raw"
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

module "nwp-national" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/services/nwp?ref=e23dda0"

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
    savedir_data = "data-national"
    savedir_raw = "raw-national"
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

module "sat" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/services/sat?ref=85d7572"

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


module "pv" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/services/pv?ref=85d7572"

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

module "gsp" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/services/gsp?ref=85d7572"

  region                  = var.region
  environment             = var.environment
  ecs-cluster             = module.ecs.ecs_cluster
  public_subnet_ids       = [module.networking.public_subnets[0].id]
  database_secret         = module.database.forecast-database-secret
  docker_version          = var.gsp_version
  iam-policy-rds-read-secret = module.database.iam-policy-forecast-db-read
}

module "metrics" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/services/metrics?ref=85d7572"

  region                  = var.region
  environment             = var.environment
  ecs-cluster             = module.ecs.ecs_cluster
  public_subnet_ids       = [module.networking.public_subnets[0].id]
  database_secret         = module.database.forecast-database-secret
  docker_version          = var.metrics_version
  iam-policy-rds-read-secret = module.database.iam-policy-forecast-db-read
}


module "forecast" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/services/forecast?ref=85d7572"

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


module "national_forecast" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/services/forecast_generic?ref=85d7572"

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
    cron_expression = "cron(15,45 * * * ? *)" # Every 10 minutes
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

module "analysis_dashboard" {
    source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/services/internal_ui?ref=5d2a494"

    region      = var.region
    environment = var.environment
    eb_app_name = "internal-ui"
    domain = local.domain
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
}



module "forecast_pvnet" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/services/forecast_generic?ref=85d7572"

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
    cron_expression = "cron(15,45 * * * ? *)" # Runs at 15 and 45 past the hour
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
  use_adjuster="true"
}

module "forecast_blend" {
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/services/forecast_blend?ref=85d7572"


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
  source = "github.com/openclimatefix/ocf-infrastructure//terraform/modules/services/airflow?ref=47dc829"

  environment   = var.environment
  vpc_id        = module.networking.vpc_id
  subnets       = [module.networking.public_subnets[0].id]
  db_url        = module.database.forecast-database-secret-airflow-url
  docker-compose-version       = "0.0.3"
  ecs_subnet=module.networking.public_subnets[0].id
  ecs_security_group=var.ecs_security_group # TODO should be able to update this to use the module
}