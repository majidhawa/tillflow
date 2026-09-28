# Task definition is always registered (registering a task def does not
# pull the image), but the ECS service — which would actually try to run
# it — is gated behind enable_service so this module is safe to apply
# before real application images exist in ECR.

locals {
  family = "${var.name_prefix}-${var.name}"

  app_container = {
    name      = var.name
    image     = var.image
    essential = true

    portMappings = [
      {
        containerPort = var.container_port
        protocol      = "tcp"
      }
    ]

    readonlyRootFilesystem = var.read_only_root_filesystem
    user                   = var.container_user

    healthCheck = {
      command     = ["CMD-SHELL", "curl -f http://localhost:${var.container_port}${var.health_check_path} || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 15
    }

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = var.log_group_name
        awslogs-region        = var.region
        awslogs-stream-prefix = var.name
      }
    }

    environment = concat(
      [
        { name = "SERVICE_NAME", value = var.name },
        { name = "AWS_REGION", value = var.region },
      ],
      var.is_backend ? [
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://localhost:4317" },
        { name = "OTEL_SERVICE_NAME", value = var.name },
        { name = "OTEL_RESOURCE_ATTRIBUTES", value = "service.name=${var.name},service.namespace=tillflow,deployment.environment=capstone" },
      ] : []
    )
  }

  # ADOT sidecar receives OTLP from the app container over localhost
  # (same task network namespace) and exports to X-Ray / CloudWatch.
  adot_container = {
    name      = "adot-collector"
    image     = var.adot_image
    essential = false

    command = ["--config=/etc/ecs/ecs-default-config.yaml"]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = var.log_group_name
        awslogs-region        = var.region
        awslogs-stream-prefix = "adot"
      }
    }

    environment = [
      { name = "AWS_REGION", value = var.region },
    ]
  }

  container_definitions = concat([local.app_container], var.is_backend ? [local.adot_container] : [])
}

resource "aws_ecs_task_definition" "this" {
  family                   = local.family
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode(local.container_definitions)

  tags = var.tags
}

resource "aws_ecs_service" "this" {
  count = var.enable_service ? 1 : 0

  name            = local.family
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  launch_type     = "FARGATE"
  desired_count   = var.desired_count

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [var.target_group_arn]
    content {
      target_group_arn = load_balancer.value
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  health_check_grace_period_seconds = var.target_group_arn == null ? null : 60

  tags = var.tags
}
