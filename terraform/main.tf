data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
data "aws_region" "current" {}

locals {
  function_name = "${var.name}-fn"
  metric_ns     = "LogsRetentionEnforcer"
}

# --------------------------- Empaquetado del código ---------------------------

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../src"
  output_path = "${path.module}/build/lambda.zip"
}

# ----------------------------------- IAM --------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda" {
  name               = "${var.name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "lambda" {
  statement {
    sid       = "DescribeLogGroups"
    actions   = ["logs:DescribeLogGroups"]
    resources = ["*"]
  }

  statement {
    sid       = "PutRetentionPolicy"
    actions   = ["logs:PutRetentionPolicy"]
    resources = ["arn:${data.aws_partition.current.partition}:logs:*:${data.aws_caller_identity.current.account_id}:log-group:*"]
  }

  statement {
    sid       = "PublishMetrics"
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = [local.metric_ns]
    }
  }

  statement {
    sid     = "OwnLogs"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/lambda/${local.function_name}:*"
    ]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = "${var.name}-policy"
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda.json
}

# ------------------------------ Log group propio ------------------------------

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = var.lambda_log_retention_in_days
  tags              = var.tags
}

# ----------------------------------- Lambda -----------------------------------

resource "aws_lambda_function" "this" {
  function_name    = local.function_name
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.12"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  timeout          = var.function_timeout
  memory_size      = var.function_memory

  environment {
    variables = {
      RETENTION_DAYS             = tostring(var.retention_in_days)
      TARGET_REGIONS             = join(",", var.target_regions)
      DRY_RUN                    = tostring(var.dry_run)
      OVERWRITE_EXISTING         = tostring(var.overwrite_existing)
      EXCLUDE_LOG_GROUP_PREFIXES   = join(",", var.exclude_log_group_prefixes)
      PROTECTED_LOG_GROUP_PATTERNS = join(",", var.protected_log_group_patterns)
      LOG_LEVEL                  = var.log_level
      METRIC_NAMESPACE           = local.metric_ns
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]
  tags       = var.tags
}

# --------------------------- EventBridge: schedule ----------------------------

resource "aws_cloudwatch_event_rule" "schedule" {
  name                = "${var.name}-schedule"
  description         = "Sweep periódico de retención de log groups."
  schedule_expression = var.schedule_expression
  tags                = var.tags
}

resource "aws_cloudwatch_event_target" "schedule" {
  rule      = aws_cloudwatch_event_rule.schedule.name
  target_id = "LogsRetentionFunction"
  arn       = aws_lambda_function.this.arn
}

resource "aws_lambda_permission" "schedule" {
  statement_id  = "AllowSchedule"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}

# ---------------------- EventBridge: CreateLogGroup ---------------------------

resource "aws_cloudwatch_event_rule" "on_create" {
  count       = var.enable_create_log_group_trigger ? 1 : 0
  name        = "${var.name}-on-create"
  description = "Aplica retención cuando se crea un nuevo log group."

  event_pattern = jsonencode({
    source        = ["aws.logs"]
    "detail-type" = ["AWS API Call via CloudTrail"]
    detail = {
      eventSource = ["logs.amazonaws.com"]
      eventName   = ["CreateLogGroup"]
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "on_create" {
  count     = var.enable_create_log_group_trigger ? 1 : 0
  rule      = aws_cloudwatch_event_rule.on_create[0].name
  target_id = "LogsRetentionFunction"
  arn       = aws_lambda_function.this.arn
}

resource "aws_lambda_permission" "on_create" {
  count         = var.enable_create_log_group_trigger ? 1 : 0
  statement_id  = "AllowOnCreate"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.this.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.on_create[0].arn
}
