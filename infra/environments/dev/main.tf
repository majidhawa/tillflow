module "network" {
  source = "../../modules/network"

  name_prefix          = var.name_prefix
  vpc_cidr             = var.vpc_cidr
  azs                  = var.azs
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  single_nat_gateway   = var.single_nat_gateway
  tags                 = var.tags
}

module "ecr" {
  source = "../../modules/ecr"

  name_prefix      = var.name_prefix
  repository_names = var.app_names
  tags             = var.tags
}

module "ecs_cluster" {
  source = "../../modules/ecs-cluster"

  cluster_name  = "${var.name_prefix}-tillflow"
  name_prefix   = var.name_prefix
  service_names = var.app_names
  tags          = var.tags
}

module "alb" {
  source = "../../modules/alb"

  name_prefix = var.name_prefix
  vpc_id      = module.network.vpc_id
  region      = var.region
  subnet_ids  = module.network.private_subnet_ids

  services = [for name in var.app_names : {
    name              = name
    container_port    = var.container_port
    health_check_path = name == "web" ? "/" : "/health"
  }]

  tags = var.tags
}

# One ECS module call per app. Backend services (pos/payments/commission)
# get the ADOT sidecar + OTEL env config; web does not.
module "ecs_service_web" {
  source = "../../modules/ecs-service"

  name               = "web"
  name_prefix        = var.name_prefix
  region             = var.region
  cluster_arn        = module.ecs_cluster.cluster_arn
  execution_role_arn = module.ecs_cluster.execution_role_arn
  task_role_arn      = module.ecs_cluster.task_role_arn
  log_group_name     = module.ecs_cluster.log_group_names["web"]
  image              = "${module.ecr.repository_urls["web"]}:${var.image_tags["web"]}"
  container_port     = var.container_port
  health_check_path  = "/"
  is_backend         = false
  private_subnet_ids = module.network.private_subnet_ids
  security_group_ids = [module.alb.ecs_tasks_security_group_id]
  target_group_arn   = module.alb.target_group_arns["web"]
  enable_service     = var.enable_services
  tags               = var.tags
}

module "ecs_service_pos" {
  source = "../../modules/ecs-service"

  name               = "pos"
  name_prefix        = var.name_prefix
  region             = var.region
  cluster_arn        = module.ecs_cluster.cluster_arn
  execution_role_arn = module.ecs_cluster.execution_role_arn
  task_role_arn      = module.ecs_cluster.task_role_arn
  log_group_name     = module.ecs_cluster.log_group_names["pos"]
  image              = "${module.ecr.repository_urls["pos"]}:${var.image_tags["pos"]}"
  container_port     = var.container_port
  health_check_path  = "/health"
  is_backend         = true
  private_subnet_ids = module.network.private_subnet_ids
  security_group_ids = [module.alb.ecs_tasks_security_group_id]
  target_group_arn   = module.alb.target_group_arns["pos"]
  enable_service     = var.enable_services
  tags               = var.tags
}

module "ecs_service_payments" {
  source = "../../modules/ecs-service"

  name               = "payments"
  name_prefix        = var.name_prefix
  region             = var.region
  cluster_arn        = module.ecs_cluster.cluster_arn
  execution_role_arn = module.ecs_cluster.execution_role_arn
  task_role_arn      = module.ecs_cluster.task_role_arn
  log_group_name     = module.ecs_cluster.log_group_names["payments"]
  image              = "${module.ecr.repository_urls["payments"]}:${var.image_tags["payments"]}"
  container_port     = var.container_port
  health_check_path  = "/health"
  is_backend         = true
  private_subnet_ids = module.network.private_subnet_ids
  security_group_ids = [module.alb.ecs_tasks_security_group_id]
  target_group_arn   = module.alb.target_group_arns["payments"]
  enable_service     = var.enable_services
  tags               = var.tags
}

module "ecs_service_commission" {
  source = "../../modules/ecs-service"

  name               = "commission"
  name_prefix        = var.name_prefix
  region             = var.region
  cluster_arn        = module.ecs_cluster.cluster_arn
  execution_role_arn = module.ecs_cluster.execution_role_arn
  task_role_arn      = module.ecs_cluster.task_role_arn
  log_group_name     = module.ecs_cluster.log_group_names["commission"]
  image              = "${module.ecr.repository_urls["commission"]}:${var.image_tags["commission"]}"
  container_port     = var.container_port
  health_check_path  = "/health"
  is_backend         = true
  private_subnet_ids = module.network.private_subnet_ids
  security_group_ids = [module.alb.ecs_tasks_security_group_id]
  target_group_arn   = module.alb.target_group_arns["commission"]
  enable_service     = var.enable_services
  tags               = var.tags
}

# --- G1 remaining platform infrastructure ---

module "rds_postgres" {
  source = "../../modules/rds-postgres"

  name_prefix                 = var.name_prefix
  vpc_id                      = module.network.vpc_id
  private_subnet_ids          = module.network.private_subnet_ids
  ecs_tasks_security_group_id = module.alb.ecs_tasks_security_group_id
  ecs_task_role_name          = module.ecs_cluster.task_role_name

  engine_version    = var.rds_engine_version
  instance_class    = var.rds_instance_class
  allocated_storage = var.rds_allocated_storage
  db_name           = var.rds_db_name

  tags = var.tags
}

module "redis" {
  source = "../../modules/redis"

  name_prefix                 = var.name_prefix
  vpc_id                      = module.network.vpc_id
  private_subnet_ids          = module.network.private_subnet_ids
  ecs_tasks_security_group_id = module.alb.ecs_tasks_security_group_id

  engine         = var.redis_engine
  engine_version = var.redis_engine_version
  node_type      = var.redis_node_type

  tags = var.tags
}

module "sqs" {
  source = "../../modules/sqs"

  name_prefix        = var.name_prefix
  queue_name         = var.sqs_queue_name
  ecs_task_role_name = module.ecs_cluster.task_role_name

  tags = var.tags
}

module "s3_buckets" {
  source = "../../modules/s3-buckets"

  name_prefix        = var.name_prefix
  purposes           = var.s3_purposes
  expiration_days    = var.s3_expiration_days
  ecs_task_role_name = module.ecs_cluster.task_role_name

  tags = var.tags
}

module "commission_schedule" {
  source = "../../modules/eventbridge-schedule"

  name_prefix         = var.name_prefix
  schedule_expression = var.commission_schedule_expression

  tags = var.tags
}

module "app_secrets" {
  source = "../../modules/secrets-placeholders"

  name_prefix        = var.name_prefix
  secrets            = var.app_secret_placeholders
  ecs_task_role_name = module.ecs_cluster.task_role_name

  tags = var.tags
}

module "github_oidc_roles" {
  source = "../../modules/github-oidc-roles"

  name_prefix        = var.name_prefix
  region             = var.region
  github_org         = var.github_org
  github_repo        = var.github_repo
  github_environment = var.github_environment
  ecs_cluster_name   = module.ecs_cluster.cluster_name
  app_names          = var.app_names

  terraform_state_bucket_name = var.terraform_state_bucket_name

  tags = var.tags
}

module "apigw" {
  source = "../../modules/apigw-vpclink"

  name_prefix           = var.name_prefix
  vpc_id                = module.network.vpc_id
  private_subnet_ids    = module.network.private_subnet_ids
  alb_security_group_id = module.alb.alb_security_group_id
  alb_listener_arn      = module.alb.listener_arn
  alb_listener_port     = 80

  tags = var.tags
}

# The ALB security group has no ingress rule of its own (see
# infra/modules/alb). This is the only permitted ingress: HTTP on the
# listener port, sourced strictly from the API Gateway VPC Link security
# group — never 0.0.0.0/0. It lives here, not inside either module,
# because module.alb and module.apigw would otherwise form a circular
# dependency (apigw already depends on alb's security group/listener
# outputs).
resource "aws_security_group_rule" "alb_ingress_from_apigw_vpc_link" {
  type                     = "ingress"
  security_group_id        = module.alb.alb_security_group_id
  source_security_group_id = module.apigw.vpc_link_security_group_id
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  description              = "API Gateway VPC Link to ALB listener"
}
