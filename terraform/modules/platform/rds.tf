locals {
  # Cada serviço com persistência relacional tem seu próprio banco (database-per-service).
  databases = {
    ngo      = { db_name = "ngo_db", service = "ngo-service" }
    donation = { db_name = "donation_db", service = "donation-service" }
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-db-subnet"
  subnet_ids = module.vpc.private_subnets

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-db-subnet" })
}

resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg"
  description = "Permite acesso PostgreSQL apenas a partir dos nos do EKS"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description     = "PostgreSQL a partir do EKS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [module.eks.node_security_group_id]
  }

  egress {
    description = "Saida liberada"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${local.name_prefix}-rds-sg" })
}

resource "random_password" "db" {
  for_each = local.databases

  length  = 24
  special = false
}

resource "aws_db_instance" "this" {
  for_each = local.databases

  identifier     = "${local.name_prefix}-${each.key}"
  engine         = "postgres"
  engine_version = "15"
  instance_class = var.rds_instance_class

  allocated_storage     = var.rds_allocated_storage
  max_allocated_storage = var.rds_allocated_storage * 2
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = each.value.db_name
  username = "solidary_admin"
  password = random_password.db[each.key].result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  # Base do RPO declarado no PCN: snapshots automáticos diários.
  backup_retention_period = var.rds_backup_retention_days
  backup_window           = "03:00-04:00"
  maintenance_window      = "sun:04:30-sun:05:30"
  copy_tags_to_snapshot   = true

  skip_final_snapshot       = false
  final_snapshot_identifier = "${local.name_prefix}-${each.key}-final"
  deletion_protection       = false

  performance_insights_enabled = false
  auto_minor_version_upgrade   = true

  tags = merge(local.common_tags, {
    Name    = "${local.name_prefix}-${each.key}"
    Service = each.value.service
  })
}

# ── Secrets Manager: DATABASE_URL consumida pelo External Secrets Operator ──
resource "aws_secretsmanager_secret" "db_url" {
  for_each = local.databases

  name                    = "${var.project}/${lower(var.environment)}/${each.value.service}/database-url"
  description             = "Connection string PostgreSQL do ${each.value.service}"
  recovery_window_in_days = 0

  tags = merge(local.common_tags, { Service = each.value.service })
}

resource "aws_secretsmanager_secret_version" "db_url" {
  for_each = local.databases

  secret_id = aws_secretsmanager_secret.db_url[each.key].id
  secret_string = jsonencode({
    DATABASE_URL = format(
      "postgresql://%s:%s@%s/%s?sslmode=require",
      aws_db_instance.this[each.key].username,
      random_password.db[each.key].result,
      aws_db_instance.this[each.key].endpoint,
      each.value.db_name,
    )
  })
}
