"""
LogsRetentionPeriodChange
=========================

Lambda que aplica una política de retención de CloudWatch Logs sobre log groups.

Triggers soportados:
  1. EventBridge schedule (sweep periódico).
  2. EventBridge rule sobre el evento CloudTrail `CreateLogGroup`
     (aplicación inmediata cuando se crea un log group nuevo).
  3. Invocación manual: el evento puede traer
     `{"regions": ["us-east-1", ...], "dryRun": true}` para overrides puntuales.

Variables de entorno:
  RETENTION_DAYS              Retención objetivo (por defecto 30). Debe ser un
                              valor permitido por CloudWatch Logs.
  TARGET_REGIONS              Lista separada por comas. Por defecto la región
                              en la que corre la Lambda.
  DRY_RUN                     "true" para reportar sin aplicar cambios.
  OVERWRITE_EXISTING          "true" para forzar también log groups que ya
                              tengan retención distinta a la objetivo.
  EXCLUDE_LOG_GROUP_PREFIXES  Lista separada por comas de prefijos a ignorar.
  PROTECTED_LOG_GROUP_PATTERNS
                              Lista separada por comas de regex (sin distinguir
                              mayúsculas) que NUNCA serán modificados. Se añade
                              a una lista por defecto que protege CloudTrail y
                              AWS Config.
  METRIC_NAMESPACE            Namespace para las métricas (default
                              LogsRetentionEnforcer).
  LOG_LEVEL                   Nivel del logger (default INFO).
"""

from __future__ import annotations

import json
import logging
import os
import re
from datetime import datetime, timezone
from typing import Any, Dict, List, Pattern

import boto3
from botocore.config import Config
from botocore.exceptions import ClientError

LOGGER = logging.getLogger()
LOGGER.setLevel(os.environ.get("LOG_LEVEL", "INFO"))

VALID_RETENTION = {
    1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180,
    365, 400, 545, 731, 1827, 2192, 2557, 2922, 3288, 3653,
}

RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "30"))
DRY_RUN = os.environ.get("DRY_RUN", "false").strip().lower() == "true"
OVERWRITE_EXISTING = os.environ.get("OVERWRITE_EXISTING", "false").strip().lower() == "true"
DEFAULT_REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION") or "us-east-1"
TARGET_REGIONS = [
    r.strip()
    for r in os.environ.get("TARGET_REGIONS", DEFAULT_REGION).split(",")
    if r.strip()
]
EXCLUDE_PREFIXES = [
    p.strip()
    for p in os.environ.get("EXCLUDE_LOG_GROUP_PREFIXES", "").split(",")
    if p.strip()
]

# Log groups que nunca se deben modificar. CloudTrail y AWS Config tienen
# requisitos de retención dictados por compliance, así que quedan protegidos
# por defecto y no pueden desactivarse vía configuración.
DEFAULT_PROTECTED_PATTERNS = [
    r"^/aws/cloudtrail(/|$)",
    r"^aws-cloudtrail-logs(-|$)",
    r"^/aws/config(/|$)",
    r"^/aws/events/config(/|$)",
    r"(^|/)CloudTrail/",
    r"(^|/)Config/",
]

EXTRA_PROTECTED_PATTERNS = [
    p.strip()
    for p in os.environ.get("PROTECTED_LOG_GROUP_PATTERNS", "").split(",")
    if p.strip()
]

PROTECTED_PATTERNS: List[Pattern[str]] = [
    re.compile(p, re.IGNORECASE)
    for p in DEFAULT_PROTECTED_PATTERNS + EXTRA_PROTECTED_PATTERNS
]
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "LogsRetentionEnforcer")

if RETENTION_DAYS not in VALID_RETENTION:
    raise ValueError(
        f"RETENTION_DAYS={RETENTION_DAYS} no es válido. "
        f"Debe ser uno de {sorted(VALID_RETENTION)}"
    )

BOTO_CFG = Config(retries={"max_attempts": 10, "mode": "adaptive"})


def _logs(region: str):
    return boto3.client("logs", region_name=region, config=BOTO_CFG)


def _cw(region: str):
    return boto3.client("cloudwatch", region_name=region, config=BOTO_CFG)


def _is_excluded(name: str) -> bool:
    return any(name.startswith(p) for p in EXCLUDE_PREFIXES)


def _is_protected(name: str) -> bool:
    return any(p.search(name) for p in PROTECTED_PATTERNS)


def _new_summary(region: str) -> Dict[str, Any]:
    return {
        "region": region,
        "scanned": 0,
        "reported": [],
        "updated": [],
        "alreadyCompliant": [],
        "skipped": [],
        "protected": [],
        "failed": [],
    }


def _handle_group(client, lg: Dict[str, Any], region: str, summary: Dict[str, Any]) -> None:
    name = lg["logGroupName"]
    current = lg.get("retentionInDays")
    summary["scanned"] += 1
    summary["reported"].append({"name": name, "currentRetention": current})

    if _is_protected(name):
        LOGGER.info("[%s] protected (CloudTrail/Config/custom): %s", region, name)
        summary["protected"].append(name)
        return

    if _is_excluded(name):
        LOGGER.info("[%s] excluded by prefix: %s", region, name)
        summary["skipped"].append(name)
        return

    needs_update = current is None or (OVERWRITE_EXISTING and current != RETENTION_DAYS)
    if not needs_update:
        summary["alreadyCompliant"].append(name)
        return

    LOGGER.info(
        "[%s] target=%s current=%s dry_run=%s name=%s",
        region, RETENTION_DAYS, current, DRY_RUN, name,
    )
    if DRY_RUN:
        return

    try:
        client.put_retention_policy(logGroupName=name, retentionInDays=RETENTION_DAYS)
        summary["updated"].append(name)
        LOGGER.info("[%s] updated %s -> %s days", region, name, RETENTION_DAYS)
    except ClientError as exc:
        LOGGER.exception("[%s] failed updating %s", region, name)
        summary["failed"].append({"name": name, "error": str(exc)})


def _scan_region(region: str) -> Dict[str, Any]:
    LOGGER.info("Scanning region %s", region)
    client = _logs(region)
    summary = _new_summary(region)
    paginator = client.get_paginator("describe_log_groups")
    for page in paginator.paginate():
        for lg in page.get("logGroups", []):
            _handle_group(client, lg, region, summary)
    _emit_metrics(region, summary)
    LOGGER.info(
        "[%s] done: scanned=%d updated=%d compliant=%d skipped=%d protected=%d failed=%d",
        region, summary["scanned"], len(summary["updated"]),
        len(summary["alreadyCompliant"]), len(summary["skipped"]),
        len(summary["protected"]), len(summary["failed"]),
    )
    return summary


def _process_single(region: str, log_group_name: str) -> Dict[str, Any]:
    LOGGER.info("Processing single log group %s in %s", log_group_name, region)
    client = _logs(region)
    summary = _new_summary(region)
    paginator = client.get_paginator("describe_log_groups")
    for page in paginator.paginate(logGroupNamePrefix=log_group_name):
        for lg in page.get("logGroups", []):
            if lg["logGroupName"] != log_group_name:
                continue
            _handle_group(client, lg, region, summary)
    if summary["scanned"] == 0:
        LOGGER.warning("[%s] log group %s not found", region, log_group_name)
    _emit_metrics(region, summary)
    return summary


def _emit_metrics(region: str, summary: Dict[str, Any]) -> None:
    try:
        _cw(region).put_metric_data(
            Namespace=METRIC_NAMESPACE,
            MetricData=[
                _metric("LogGroupsScanned", summary["scanned"], region),
                _metric("LogGroupsUpdated", len(summary["updated"]), region),
                _metric("LogGroupsCompliant", len(summary["alreadyCompliant"]), region),
                _metric("LogGroupsFailed", len(summary["failed"]), region),
                _metric("LogGroupsSkipped", len(summary["skipped"]), region),
                _metric("LogGroupsProtected", len(summary["protected"]), region),
            ],
        )
    except ClientError:
        LOGGER.exception("Could not publish metrics in %s", region)


def _metric(name: str, value: int, region: str) -> Dict[str, Any]:
    return {
        "MetricName": name,
        "Value": value,
        "Unit": "Count",
        "Dimensions": [{"Name": "Region", "Value": region}],
    }


def lambda_handler(event: Dict[str, Any], context) -> Dict[str, Any]:
    LOGGER.info("Event: %s", json.dumps(event) if event else "{}")
    event = event or {}

    # Trigger: CreateLogGroup vía CloudTrail
    if event.get("detail-type") == "AWS API Call via CloudTrail":
        detail = event.get("detail", {}) or {}
        if detail.get("eventName") == "CreateLogGroup":
            region = detail.get("awsRegion", DEFAULT_REGION)
            lg_name = (detail.get("requestParameters") or {}).get("logGroupName")
            if not lg_name:
                LOGGER.warning("CreateLogGroup event missing logGroupName")
                return _response([], event)
            return _response([_process_single(region, lg_name)], event)

    # Trigger: schedule o invocación manual
    regions: List[str] = event.get("regions") or TARGET_REGIONS
    summaries = [_scan_region(r) for r in regions]
    return _response(summaries, event)


def _response(summaries: List[Dict[str, Any]], event: Dict[str, Any]) -> Dict[str, Any]:
    body = {
        "retentionDays": RETENTION_DAYS,
        "dryRun": DRY_RUN,
        "overwriteExisting": OVERWRITE_EXISTING,
        "regions": [s["region"] for s in summaries],
        "summaries": summaries,
        "timestamp": datetime.now(timezone.utc).isoformat(),
    }
    return {"statusCode": 200, "body": json.dumps(body, default=str)}


if __name__ == "__main__":
    print(lambda_handler({}, None))
