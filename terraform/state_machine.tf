############################################
# Step Functions: sweep paginado >15 minutos
############################################

resource "aws_cloudwatch_log_group" "state_machine" {
  name              = "/aws/states/${var.name}-sm"
  retention_in_days = var.lambda_log_retention_in_days
  tags              = var.tags
}

data "aws_iam_policy_document" "state_machine_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "state_machine" {
  name               = "${var.name}-sm-role"
  assume_role_policy = data.aws_iam_policy_document.state_machine_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "state_machine" {
  statement {
    sid     = "InvokeFunction"
    actions = ["lambda:InvokeFunction"]
    resources = [
      aws_lambda_function.this.arn,
      "${aws_lambda_function.this.arn}:*"
    ]
  }

  statement {
    sid = "StepFunctionsLogging"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "state_machine" {
  name   = "${var.name}-sm-policy"
  role   = aws_iam_role.state_machine.id
  policy = data.aws_iam_policy_document.state_machine.json
}

locals {
  state_machine_definition = jsonencode({
    Comment = "Sweep paginado y resiliente >15min"
    StartAt = "ParseInput"
    States = {
      ParseInput = {
        Type = "Pass"
        Parameters = {
          "regions.$" = "States.StringSplit($.regionsCsv, ',')"
        }
        Next = "FanOutByRegion"
      }
      FanOutByRegion = {
        Type           = "Map"
        ItemsPath      = "$.regions"
        MaxConcurrency = 5
        ItemSelector = {
          "region.$" = "$$.Map.Item.Value"
          action     = "scanPage"
        }
        ItemProcessor = {
          ProcessorConfig = { Mode = "INLINE" }
          StartAt         = "ScanPage"
          States = {
            ScanPage = {
              Type     = "Task"
              Resource = "arn:aws:states:::lambda:invoke"
              Parameters = {
                FunctionName = aws_lambda_function.this.arn
                "Payload.$"  = "$"
              }
              OutputPath = "$.Payload"
              Retry = [{
                ErrorEquals = [
                  "Lambda.ServiceException",
                  "Lambda.AWSLambdaException",
                  "Lambda.SdkClientException",
                  "States.TaskFailed",
                ]
                IntervalSeconds = 5
                BackoffRate     = 2
                MaxAttempts     = 5
              }]
              Next = "More?"
            }
            "More?" = {
              Type = "Choice"
              Choices = [{
                Variable      = "$.done"
                BooleanEquals = false
                Next          = "PrepareNextPage"
              }]
              Default = "RegionDone"
            }
            PrepareNextPage = {
              Type = "Pass"
              Parameters = {
                action        = "scanPage"
                "region.$"    = "$.region"
                "nextToken.$" = "$.nextToken"
              }
              Next = "ScanPage"
            }
            RegionDone = { Type = "Succeed" }
          }
        }
        End = true
      }
    }
  })
}

resource "aws_sfn_state_machine" "this" {
  name       = "${var.name}-sm"
  type       = "STANDARD"
  role_arn   = aws_iam_role.state_machine.arn
  definition = local.state_machine_definition

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.state_machine.arn}:*"
    include_execution_data = false
    level                  = "ERROR"
  }

  tags = var.tags
}

############################################
# EventBridge -> State Machine (schedule)
############################################

data "aws_iam_policy_document" "events_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "events_to_sfn" {
  name               = "${var.name}-events-role"
  assume_role_policy = data.aws_iam_policy_document.events_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "events_to_sfn" {
  name = "${var.name}-events-policy"
  role = aws_iam_role.events_to_sfn.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.this.arn
    }]
  })
}
