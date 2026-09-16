# Single-node cache (no cluster mode, no replicas) in private subnets
# only, reachable solely from the existing ECS tasks security group.
# In-transit and at-rest encryption enabled; no AUTH token configured to
# keep this lab setup simple — add one later if a stricter posture is needed.

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name_prefix}-redis-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = var.tags
}

resource "aws_security_group" "redis" {
  name        = "${var.name_prefix}-redis-sg"
  description = "Redis/Valkey: ingress only from the ECS tasks security group, no egress"
  vpc_id      = var.vpc_id

  # No egress rule: same reasoning as infra/modules/rds-postgres — Redis
  # never needs outbound access, and omitting the rule here is a real
  # deny-all (Terraform strips AWS's implicit default egress-all rule).

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-redis-sg"
  })
}

resource "aws_security_group_rule" "redis_ingress_from_ecs" {
  type                     = "ingress"
  security_group_id        = aws_security_group.redis.id
  source_security_group_id = var.ecs_tasks_security_group_id
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  description              = "ECS tasks to Redis/Valkey"
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name_prefix}-redis"
  description          = "TillFlow capstone cache (${var.engine})"

  engine         = var.engine
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = 6379

  num_cache_clusters         = 1
  automatic_failover_enabled = false

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.redis.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  tags = var.tags
}
