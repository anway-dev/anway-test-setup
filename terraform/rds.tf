resource "aws_db_subnet_group" "main" {
  name       = "${var.cluster_name}-db"
  subnet_ids = module.vpc.private_subnets
}

resource "aws_security_group" "rds" {
  name   = "${var.cluster_name}-rds-sg"
  vpc_id = module.vpc.vpc_id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [module.vpc.vpc_cidr_block]
  }
}

resource "aws_db_instance" "main" {
  identifier        = "${var.cluster_name}-pg"
  engine            = "postgres"
  engine_version    = "15.4"
  instance_class    = var.db_instance_class
  allocated_storage = 20

  db_name  = "anway_demo"
  username = "anway"
  password = var.db_password  # from TF_VAR_db_password — never stored in state unencrypted (use state encryption)

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  backup_retention_period = 3
  skip_final_snapshot     = true
  deletion_protection     = false

  tags = {
    Environment = var.environment
  }
}

# Store DB URL in Secrets Manager — services read from here, not from env directly
resource "aws_secretsmanager_secret" "db_url" {
  name                    = "/${var.cluster_name}/db-url"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_url" {
  secret_id     = aws_secretsmanager_secret.db_url.id
  secret_string = "postgresql://anway:${var.db_password}@${aws_db_instance.main.endpoint}/anway_demo"
}

output "db_endpoint" {
  value     = aws_db_instance.main.endpoint
  sensitive = true
}
