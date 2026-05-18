# LogsRetentionPeriodChange

Lambda que aplica una política de retención a los CloudWatch Log Groups que no
la tengan configurada (o, opcionalmente, que tengan una distinta a la objetivo)
y registra métricas de la operación.

## Estructura

```
.
├── src/lambda_function.py        # Código de la Lambda
├── cloudformation/template.yaml  # Plantilla SAM/CFN (compatible con StackSet)
├── terraform/                    # Despliegue equivalente con Terraform
└── README.md
```

## Comportamiento

1. Lista todos los log groups de las regiones objetivo (paginado).
2. **Reporta** cada log group con su retención actual antes de tocar nada
   (visible en CloudWatch Logs y en la respuesta JSON).
3. Si la retención es `None` (o distinta y `OverwriteExisting=true`), aplica
   la retención objetivo. En `DryRun=true` solo reporta.
4. **Nunca** modifica log groups de CloudTrail ni de AWS Config: están
   protegidos por defecto vía patrones regex (case-insensitive). Puedes añadir
   más patrones con `ProtectedLogGroupPatterns`, pero los defaults no se
   pueden desactivar.
5. Publica métricas en el namespace `LogsRetentionEnforcer`:
   `LogGroupsScanned`, `LogGroupsUpdated`, `LogGroupsCompliant`,
   `LogGroupsFailed`, `LogGroupsSkipped`, `LogGroupsProtected`,
   dimensionadas por `Region`.

### Triggers
- **EventBridge schedule** (cron/rate) configurable.
- **EventBridge rule** sobre `CreateLogGroup` vía CloudTrail: en cuanto se crea
  un log group nuevo, la Lambda recibe el evento y aplica la retención al
  recién creado (sin recorrer todo).
- **Invocación manual**: `{"regions": ["us-east-1"], "dryRun": true}`.

## Parámetros

| Parámetro | Default | Descripción |
|---|---|---|
| `RetentionInDays` / `retention_in_days` | 30 | Valor permitido por CloudWatch Logs |
| `TargetRegions` / `target_regions` | región actual | Regiones a recorrer en el sweep |
| `ScheduleExpression` / `schedule_expression` | `rate(1 day)` | Frecuencia del sweep |
| `EnableCreateLogGroupTrigger` / `enable_create_log_group_trigger` | true | Habilita el trigger en `CreateLogGroup` |
| `DryRun` / `dry_run` | false | Solo reporta sin aplicar |
| `OverwriteExisting` / `overwrite_existing` | false | También sobrescribe retenciones distintas |
| `ExcludeLogGroupPrefixes` / `exclude_log_group_prefixes` | `""` | Prefijos a ignorar |
| `ProtectedLogGroupPatterns` / `protected_log_group_patterns` | `""` | Regex extra a proteger (CloudTrail y Config ya están protegidos por defecto) |
| `LogLevel` / `log_level` | INFO | Nivel del logger |

## Permisos (mínimo privilegio)

- `logs:DescribeLogGroups` (`*`).
- `logs:PutRetentionPolicy` solo sobre log groups de la cuenta.
- `cloudwatch:PutMetricData` restringido al namespace `LogsRetentionEnforcer`.
- `logs:CreateLogStream` y `logs:PutLogEvents` solo sobre el log group propio
  de la Lambda.

## Despliegue con CloudFormation / SAM

```bash
cd cloudformation

# Stack regular (una región)
sam build -t template.yaml
sam deploy \
  --stack-name logs-retention-enforcer \
  --capabilities CAPABILITY_IAM \
  --resolve-s3 \
  --parameter-overrides \
    RetentionInDays=30 \
    TargetRegions=us-east-1 \
    ScheduleExpression="rate(1 day)" \
    EnableCreateLogGroupTrigger=true
```

### StackSet (multi-cuenta y/o multi-región)

Para que cada región maneje sus propios log groups, conviene desplegar la
Lambda en cada región del StackSet con `TargetRegions=<AWS::Region>`:

```bash
aws cloudformation create-stack-set \
  --stack-set-name logs-retention-enforcer \
  --template-body file://cloudformation/template.yaml \
  --capabilities CAPABILITY_IAM \
  --permission-model SERVICE_MANAGED \
  --auto-deployment Enabled=true,RetainStacksOnAccountRemoval=false \
  --parameters \
      ParameterKey=RetentionInDays,ParameterValue=30 \
      ParameterKey=TargetRegions,ParameterValue=${AWS::Region} \
      ParameterKey=EnableCreateLogGroupTrigger,ParameterValue=true

aws cloudformation create-stack-instances \
  --stack-set-name logs-retention-enforcer \
  --deployment-targets OrganizationalUnitIds=ou-xxxx-xxxxxxxx \
  --regions us-east-1 us-east-2 eu-west-1 \
  --operation-preferences FailureToleranceCount=1,MaxConcurrentCount=5
```

Notas para StackSet:
- La plantilla no usa recursos globales conflictivos: nombres incluyen
  `AWS::StackName`, así que pueden coexistir varias instancias en cuentas
  distintas.
- Para que el trigger de `CreateLogGroup` funcione, la cuenta destino debe
  tener un trail de CloudTrail capturando eventos de gestión en cada región.
- Si prefieres una única Lambda central que recorra varias regiones, despliega
  un stack normal con `TargetRegions=us-east-1,us-east-2,...` y permisos
  cross-region (los permisos de `logs` son por región, así que en ese modelo
  la Lambda igual usa el mismo rol pero cliente distinto por región).

## Despliegue con Terraform

```bash
cd terraform
terraform init
terraform apply -var-file=example.tfvars
```

Para multi-región puedes:
- Llamar al módulo varias veces con distintos `provider` aliasados.
- O setear `target_regions = ["us-east-1", "us-east-2"]` y dejar una sola
  Lambda recorriendo todas (un solo cron, varios clientes regionales).

## Métricas y observabilidad

- CloudWatch Logs: `/aws/lambda/<stack>-fn` con retención propia configurable.
- CloudWatch Metrics: namespace `LogsRetentionEnforcer`, dimensión `Region`.
- Respuesta de la Lambda incluye el inventario reportado y el detalle de
  `updated`, `alreadyCompliant`, `skipped` y `failed`.

## Pruebas locales

```bash
RETENTION_DAYS=30 TARGET_REGIONS=us-east-1 DRY_RUN=true \
  python src/lambda_function.py
```
