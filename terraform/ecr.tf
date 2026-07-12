locals {
  services = [
    "api-gateway", "auth-service", "user-service", "product-service",
    "cart-service", "order-service", "payment-service", "inventory-service",
    "notification-service", "search-service", "recommendation-service",
    "review-service", "shipping-service", "analytics-service", "admin-service",
    "traffic-simulator", "chaos-runner"
  ]
}

resource "aws_ecr_repository" "services" {
  for_each = toset(local.services)

  name                 = "${var.cluster_name}/${each.key}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Environment = var.environment
    Service     = each.key
  }
}

resource "aws_ecr_lifecycle_policy" "keep_last_20" {
  for_each   = aws_ecr_repository.services
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 20 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 20
      }
      action = { type = "expire" }
    }]
  })
}

output "ecr_registry" {
  value = split("/", aws_ecr_repository.services["api-gateway"].repository_url)[0]
}

output "ecr_repositories" {
  value = { for k, v in aws_ecr_repository.services : k => v.repository_url }
}
