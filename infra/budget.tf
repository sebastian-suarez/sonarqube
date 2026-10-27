resource "aws_budgets_budget" "sonarqube" {
  name         = "sonarqube"
  budget_type  = "COST"
  limit_amount = "10"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$sonarqube"]
  }

  dynamic "notification" {
    for_each = ["ACTUAL", "FORECASTED"]

    content {
      notification_type          = notification.value
      comparison_operator        = "GREATER_THAN"
      threshold                  = 100
      threshold_type             = "PERCENTAGE"
      subscriber_email_addresses = ["aws@sebastiansuarez.dev"]
    }
  }
}
