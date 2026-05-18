output "function_arn" {
  value = aws_lambda_function.this.arn
}

output "function_role_arn" {
  value = aws_iam_role.lambda.arn
}

output "schedule_rule_arn" {
  value = aws_cloudwatch_event_rule.schedule.arn
}

output "create_log_group_rule_arn" {
  value = try(aws_cloudwatch_event_rule.on_create[0].arn, null)
}
