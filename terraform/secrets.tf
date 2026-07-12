# JWT secret for auth-service
resource "aws_secretsmanager_secret" "jwt_secret" {
  name                    = "/${var.cluster_name}/jwt-secret"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "jwt_secret" {
  secret_id     = aws_secretsmanager_secret.jwt_secret.id
  secret_string = var.jwt_secret
}

# IRSA for services to read secrets from Secrets Manager
resource "aws_iam_policy" "secrets_read" {
  name = "${var.cluster_name}-secrets-read"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_secretsmanager_secret.db_url.arn,
        aws_secretsmanager_secret.jwt_secret.arn,
      ]
    }]
  })
}

module "app_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "${var.cluster_name}-app"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["demo:demo-services"]
    }
  }

  role_policy_arns = {
    secrets = aws_iam_policy.secrets_read.arn
  }
}

output "app_irsa_role_arn" {
  value = module.app_irsa.iam_role_arn
}
