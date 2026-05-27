# LogsRetentionPeriodChange

Lambda que aplica una política de retención a los CloudWatch Log Groups que no
la tengan configurada (o, opcionalmente, que tengan una distinta a la objetivo)
y registra métricas de la operación.

## Estructura

```
.
├── src/lambda_function.py        # Código de la Lambda
├── cloudformation/template.yaml  # Plantilla SAM/CFN (Lambda + Step Functions)
├── terraform/                    # Despliegue equivalente con Terraform
└── README.md
```

## Arquitectura

```
EventBridge (schedule)
        │
        ▼
   Step Functions (Standard, hasta 1 año)
        │
   ┌────┴────┐ Map por región (concurrencia 5)
   ▼         ▼
ScanPage → ScanPage → ... (loop hasta done=true)
        │
        ▼
      Lambda (action=scanPage, max ~14 min por página)

EventBridge rule (CreateLogGroup) ──────► Lambda (procesa solo el nuevo)
```

- **Sweep periódico**: el schedule arranca la **State Machine**, no la Lambda.
  La state machine pagina por región y reinvoca la Lambda hasta terminar, así
  el escaneo total puede durar lo que haga falta (Standard SFN ≤ 1 año por
  ejecución).
- **CreateLogGroup**: sigue siendo Lambda directa, una invocación por evento.
- **Cada invocación de la Lambda** procesa páginas hasta acercarse al timeout
  (`SAFETY_MARGIN_MS`, default 20 s) y devuelve `nextToken` si queda trabajo.

## Comportamiento

1. Lista todos los log groups de las regiones objetivo (paginado).
2. **Reporta** cada log group con su retención actual antes de tocar nada
   (visible en CloudWatch Logs y en la respuesta JSON).
3. Si la retención es `None` **o distinta a 365 días** (menor o mayor),
   aplica la retención objetivo (365 días). En `DryRun=true` solo reporta.
   - **Se tocan**: log groups sin retención (Never expire) y los que tengan
     cualquier retención distinta al target (7, 14, 30, 731, 1827…).
   - **Solo se preservan**: log groups que ya están en 365 (`alreadyCompliant`)
     y los protegidos (CloudTrail / Config).
4. **Nunca** modifica log groups de CloudTrail ni de AWS Config: están
   protegidos por defecto vía patrones regex (case-insensitive). Puedes añadir
   más patrones con `ProtectedLogGroupPatterns`, pero los defaults no se
   pueden desactivar.
5. Publica métricas en el namespace `LogsRetentionEnforcer`:
   `LogGroupsScanned`, `LogGroupsUpdated`, `LogGroupsCompliant`,
   `LogGroupsExistingRetentionPreserved`, `LogGroupsFailed`, `LogGroupsSkipped`,
   `LogGroupsProtected`, dimensionadas por `Region`.

### Triggers
- **EventBridge schedule → Step Functions** (recomendado): orquesta el sweep
  paginado y soporta cuentas grandes con tiempo total >15 minutos.
- **EventBridge rule → Lambda** sobre `CreateLogGroup` vía CloudTrail: en
  cuanto se crea un log group nuevo, la Lambda recibe el evento y aplica la
  retención al recién creado.
- **Invocación manual a la Lambda**: `{"regions": ["us-east-1"], "dryRun": true}`
  (un solo `RunTime`, limitado a 15 min).
- **Modo paginado a la Lambda**:
  `{"action": "scanPage", "region": "us-east-1", "nextToken": "..."}` →
  útil si quieres orquestar tú mismo el loop.

## Parámetros

| Parámetro | Default | Descripción |
|---|---|---|
| `RetentionInDays` / `retention_in_days` | 365 | Valor permitido por CloudWatch Logs (default 1 año) |
| `TargetRegions` / `target_regions` | us-east-1, us-east-2, us-west-2, ca-central-1 | Regiones a recorrer en el sweep |
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
    RetentionInDays=365 \
    TargetRegions=us-east-1,us-east-2,us-west-2,ca-central-1 \
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
      ParameterKey=RetentionInDays,ParameterValue=365 \
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
