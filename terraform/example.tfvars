name                            = "logs-retention-enforcer"
retention_in_days               = 365
target_regions                  = ["us-east-1"]
schedule_expression             = "rate(1 day)"
enable_create_log_group_trigger = true
dry_run                         = false
overwrite_existing              = false
exclude_log_group_prefixes      = ["/aws/audit/"]
# CloudTrail y Config quedan protegidos por defecto. Aquí solo agregas extras.
protected_log_group_patterns = []
log_level                    = "INFO"
tags = {
  Project = "LogsRetentionEnforcer"
  Owner   = "platform"
}
