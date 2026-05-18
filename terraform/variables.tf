variable "name" {
  description = "Prefijo de nombre para todos los recursos."
  type        = string
  default     = "logs-retention-enforcer"
}

variable "retention_in_days" {
  description = "Retención objetivo en días."
  type        = number
  default     = 365

  validation {
    condition = contains(
      [1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1827, 2192, 2557, 2922, 3288, 3653],
      var.retention_in_days
    )
    error_message = "retention_in_days debe ser un valor permitido por CloudWatch Logs."
  }
}

variable "target_regions" {
  description = "Regiones que la Lambda revisará en el sweep periódico."
  type        = list(string)
  default     = ["us-east-1"]
}

variable "schedule_expression" {
  description = "Expresión EventBridge para el sweep periódico."
  type        = string
  default     = "rate(1 day)"
}

variable "enable_create_log_group_trigger" {
  description = "Crea EventBridge rule sobre CreateLogGroup."
  type        = bool
  default     = true
}

variable "dry_run" {
  description = "Solo reportar, no aplicar cambios."
  type        = bool
  default     = false
}

variable "overwrite_existing" {
  description = "Forzar también log groups con retención distinta."
  type        = bool
  default     = false
}

variable "exclude_log_group_prefixes" {
  description = "Lista de prefijos a excluir."
  type        = list(string)
  default     = []
}

variable "protected_log_group_patterns" {
  description = <<EOT
Regex (case-insensitive) de log groups adicionales que NUNCA deben ser
modificados. Se concatena a la lista por defecto que ya protege CloudTrail y
AWS Config.
EOT
  type        = list(string)
  default     = []
}

variable "log_level" {
  description = "Nivel de log de la Lambda."
  type        = string
  default     = "INFO"
  validation {
    condition     = contains(["DEBUG", "INFO", "WARNING", "ERROR"], var.log_level)
    error_message = "log_level debe ser DEBUG, INFO, WARNING o ERROR."
  }
}

variable "function_timeout" {
  type    = number
  default = 300
}

variable "function_memory" {
  type    = number
  default = 256
}

variable "lambda_log_retention_in_days" {
  description = "Retención del log group de esta misma Lambda."
  type        = number
  default     = 30
}

variable "tags" {
  type    = map(string)
  default = {}
}
