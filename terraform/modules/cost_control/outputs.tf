output "budget_name" {
  description = "Monthly AWS cost budget name."
  value       = aws_budgets_budget.monthly.name
}

output "monthly_budget_limit_usd" {
  description = "Configured monthly AWS account cost ceiling."
  value       = var.monthly_budget_limit_usd
}

output "notification_thresholds" {
  description = "Actual and forecast alert percentages."
  value = {
    actual_percent   = var.actual_alert_threshold_percent
    forecast_percent = var.forecast_alert_threshold_percent
  }
}
