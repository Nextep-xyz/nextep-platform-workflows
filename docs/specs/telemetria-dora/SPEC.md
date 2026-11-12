# SPEC — Telemetría DORA con OIDC (activación del bloque `DORA-PLACEHOLDER`)

> Activa el job `telemetry-phone-home` en `lego-aws-cicd` y `lego-aws-environment-deploy` con el contrato del colector
> (enmiendas C1–C9 de su spec, repositorio privado de diseño). **Sustituye a `SPEC.md` §9** (HMAC, `TELEMETRY_TOKEN`,
> `actor`, `lead_time_s`) y enmienda §6.5/G2 y §10/G7 (ver §3.2).
> **Estado: APROBADO (2026-11-12) v0.1. Ejecución fase por fase (§7); estado en §10.**
>
> **Este repo es PÚBLICO.** Aquí no hay nombres de proyectos, organizaciones, dominios ni cuentas internas: el colector entra
> solo por `inputs`/`vars` del caller. En los ejemplos: `example-org`, `example-service`, `shop`, `<ACCOUNT>`.

| | |
|---|---|
| **Versión del spec** | 0.1.0 (2026-11-12) |
| **Aprobador** | Mantenedores del repo (`.github/CODEOWNERS`) |
| **Ejecutor previsto** | Agente autónomo, fase por fase (§7), o un DevOps sin contexto de la conversación |
| **Release objetivo** | `v1.2.0` (aditivo, §6); el alias `v1` se mueve solo por `release.yml` |
| **Fuente del contrato** | `contracts/telemetry.schema.json` de este repo = copia **normalizada** del esquema del colector (§3.5) |
| **Preguntas abiertas** | §9 (Q6, Q7 y Q8 resueltas el 2026-11-12; Q1–Q5 no bloquean) |

---

## 1. Problema y alcance

**Problema.** Los dos workflows reutilizables terminan sin medir nada: el job de telemetría está escrito y **comentado**
(`# DORA-PLACEHOLDER:BEGIN/END`, gate G17 falla si se descomenta) con un diseño que el colector ya descartó: firma HMAC con
`TELEMETRY_TOKEN`, `source.actor` y `timing.lead_time_s`. El colector autentica con **GitHub OIDC** (audiencia propia) y
**contrasta el body con los claims del token**, así que el emisor tiene que producir exactamente lo que él verifica.

**Entra:**

- Quitar `TELEMETRY_TOKEN`/HMAC, `source.actor` y `timing.lead_time_s` (C1, C3, C5).
- Inputs `telemetry-url` (ya reservado) y `telemetry-audience` (nuevo), ambos opcionales y vacíos por defecto (C1).
- Job `telemetry-phone-home` con `id-token: write` **sin credenciales cloud** (C2) y la enmienda de G2.
- `source.tree_sha` y `source.ancestry[]` con **una** llamada a la API de commits (C4).
- `target.environment` como etiqueta cruda y `target.project` como slug (C6, C7).
- Tiempos por etapa (stamps por job), resultado derivado de `needs`, resumen del run con el payload y el `job_workflow_ref` real.
- Resiliencia: `continue-on-error`, timeout corto, nunca rompe el pipeline; qué significa "reenviar" (§3.6).
- Versionado: `v1.2.0` + alias `v1`, y la condición `job_workflow_ref` del colector (§6).
- Gate G17 **actualizado** (no borrado) + guards nuevos T1–T13 (§4).

**Queda explícitamente fuera:**

- Modificar el colector o su repo (se **lee**; sus cambios los hace su sesión).
- Modificar el workflow del primer consumidor (`telemetry-url`/`telemetry-audience` por `vars`): lo hace la sesión del consumidor.
- Relajar el enum `dev|stg|prod` de `validate-inputs` (la etiqueta cruda es `inputs.environment` tal cual; hoy ya es un valor válido del patrón del colector).
- `circuit_breaker_triggered` real (ningún output del cómputo ECS lo expone hoy: se envía `false`, §3.3).
- Telemetría de `lego-azure-satellite` (no existe) y de Azure DevOps.
- Comentario de PR / "pipeline chismoso" (`SPEC.md §8`): otro feature.
- Paneles, backfill, alertas: del colector.
- Corregir los puntos obsoletos de `AGENTS.md` ajenos a este cambio (se reportan, no se tocan).

---

## 2. Estado de partida (verificado leyendo el repo, 2026-11-12)

| Hecho | Evidencia |
|---|---|
| Bloque DORA comentado en ambos workflows y ambos contratos; apunta a un composite `telemetry` que **no existe** | `lego-aws-cicd.yml:193-199,392-410`, `lego-aws-environment-deploy.yml:179-185,445-463`, `contracts/*.contract.yml` |
| G17 exige el bloque comentado y falla si se activa | `test/gates/dora-placeholder.bats`; `test/bats/gates-red.bats:145-169` lo verifica en rojo |
| G2 solo admite `id-token: write` en `database-migration`, `deploy`, `infra-deploy`, `post-deploy` | `test/gates/permissions.bats` |
| `continue-on-error` solo se admite en pasos de jobs `telemetry\|report`; **no mira el nivel de job** | `test/gates/fail-hard.bats` |
| Ni `upload-artifact` ni `GITHUB_STEP_SUMMARY` se usan hoy en el repo | `grep` en `.github/`, `scripts/` |
| `validate-inputs.sh` fuerza `environment ∈ {dev,stg,prod}` y `project` con `^[a-z][a-z0-9-]{1,15}$` (= patrón del colector) | `scripts/validate-inputs.sh:38-39` |
| El `curl` falso solo escribe `--output` y devuelve un rc fijo: no sabe de URLs ni de `-w '%{http_code}'` | `test/bats/fakes/curl` |
| Tags remotos: `v1 → v1.1.1`. El `v1` **local** está viejo (`ed98477`, = v1.1.0) y `main` local va 1 commit por delante de `origin/main` | `git ls-remote --tags origin`, `git rev-parse main origin/main` |
| Los callers del sandbox usan `@main` (fixtures; con `@main` el colector respondería 403 por diseño, §6) | `test/sandbox/callers/*.yml` |
| Todos los callers del sandbox ya conceden `id-token: write` (los jobs `deploy`/`database-migration` ya lo exigen) | idem |

**Lo que el colector verifica de nuestro lado** (leído en su spec §5.2/§6.1 y en su `authorize.ts`, solo lectura):

| Comprobación | Consecuencia para el emisor |
|---|---|
| `job_workflow_ref` ∈ `^<org>/nextep-platform-workflows/\.github/workflows/lego-[a-z0-9-]+\.yml@refs/tags/v[0-9]+(\.[0-9]+\.[0-9]+)?$` | Callers por **tag** (`@v1`, `@v1.2.0`); nunca `@main`, SHA ni `@v1.2` |
| `source.{repository,organization,sha,ref,run_id}` y `workflow.run_attempt` = claims del token | El payload sale **del mismo run** que mintió el token |
| `idempotency_key == "<repository>:<run_id>:<run_attempt>"` (sin distinguir mayúsculas) | Formato fijo; sin sufijo posible |
| `target.project` = slug del registro; `target.environment` mapea a un carril del proyecto | Responsabilidad del caller (§9 Q2) |
| Cuerpo ≤ 32 KB, esquema cerrado (`additionalProperties: false` en todos los niveles) | Lista blanca estricta |

---

## 3. Diseño

### 3.1 Piezas

```
quality-and-security-gate ─┐
database-migration         ├─ needs ─► telemetry-phone-home   (job nuevo, if: always(), no bloquea nada)
deploy | infra-deploy |    │             └─ composite telemetry@<SHA de release>
post-deploy               ─┘                  ├─ scripts/telemetry-fetch-commits.sh   (1 llamada a la API de commits)
                                              ├─ scripts/telemetry-build-payload.sh   (jq -n --arg, nunca interpolación)
                                              └─ scripts/telemetry-send.sh            (token OIDC + POST + resumen)
```

- **Composite `telemetry`** (`.github/actions/telemetry/action.yml`): recibe `telemetry-url`, `audience`, `flow` (`cicd`|`environment-deploy`),
  `project`, `environment`, `aws-region`, `compute`, `db-access`, `image-tag`, `needs-json` (`toJSON(needs)`) y `github-token`.
  Todo llega a los scripts por `env:`; **ningún `${{ }}` dentro de `run:`** (G5).
- **Stamps de tiempo** (F2): cada job de ambos workflows abre con un paso `Stamp the start` y cierra con `Stamp the end` (`if: always()`),
  y expone `started-at` / `finished-at` (epoch, s) como **outputs del job**. Es el único camino sin pedir permisos nuevos: la alternativa
  (API de jobs del run) exige `actions: read` y un caller que no lo conceda hace **fallar el arranque de todo el workflow** (los permisos de un
  reusable no pueden exceder los del caller). Un `run:` de una línea, sin interpolación.
- **El job no ejecuta código del caller:** sin `checkout`, sin `make`, sin comandos de `inputs`. Solo scripts de este repo, fijados por SHA al
  liberar (`release.sh` reescribe `@main` → SHA, G3/G11). Esa es la razón por la que puede tener `id-token: write` (§3.2).

### 3.2 Enmienda de la regla de `id-token` (SPEC §6.5, guard G2)

Hoy: `id-token: write` solo en los jobs que asumen el rol cloud. **Nuevo:** también en `telemetry-phone-home`, con estas condiciones, **todas con gate**:

1. `permissions` es **exactamente** `{ contents: read, id-token: write }` (ni `pull-requests`, ni `actions`, ni nada más).
2. **Sin credenciales cloud:** el job no contiene `aws-oidc`, `configure-aws-credentials`, `azure/login` ni ningún `uses` distinto del composite interno.
3. Sin `actions/checkout`, sin `run:` propio (toda la lógica vive en el composite) y sin acciones de terceros (un tercero dentro de un job con `id-token: write` podría mintar tokens: por eso **no hay `upload-artifact`**, §3.6).
4. **La audiencia no es libre** (T2): es lo que impide usar este job para sacar un token con `job_workflow_ref` de este repo y audiencia de un proveedor cloud.

> **Por qué importa el punto 4.** Un token mintado dentro de un job de nuestro reusable lleva `job_workflow_ref = lego-*.yml@v1`. Si un caller pudiera fijar
> `telemetry-audience: sts.amazonaws.com` y `telemetry-url: <suyo>`, recibiría en su servidor un token que satisface una trust policy condicionada por
> `job_workflow_ref` (SPEC D2/G1): se salta justo la barrera que D2 construye. Defensa: audiencia **solo** `^[a-z0-9][a-z0-9-]{2,62}$` (sin `.`, `:` ni `/`, lo que excluye
> los valores por defecto de AWS, Azure y GCP), validada **dentro del composite** (el gate de inputs puede haber fallado y el job corre con `always()`), y el token nunca se imprime,
> se enmascara antes del primer uso y no sale como output. Riesgo residual: un caller que conozca una audiencia cloud *sin* puntos (poco habitual) → ADR del paso F4.

### 3.3 Payload (campo a campo, esquema 1.0; `additionalProperties: false`)

| Campo | De dónde sale |
|---|---|
| `schema_version`, `event_type` | constantes `"1.0"`, `"deployment"` |
| `idempotency_key` | `$GITHUB_REPOSITORY:$GITHUB_RUN_ID:$GITHUB_RUN_ATTEMPT` |
| `emitted_at` | `date -u` al construir |
| `workflow.name`, `.version_ref`, `.sha` | **del propio token**: `job_workflow_ref` (basename sin `.yml` / lo que va tras `@`) y `job_workflow_sha`. Así el payload y lo que el colector valida no pueden divergir |
| `workflow.run_attempt` | `$GITHUB_RUN_ATTEMPT` |
| `source.organization`, `.repository`, `.ref`, `.sha`, `.event_name`, `.run_id` | `$GITHUB_REPOSITORY_OWNER`, `$GITHUB_REPOSITORY`, `$GITHUB_REF`, `$GITHUB_SHA`, `$GITHUB_EVENT_NAME`, `$GITHUB_RUN_ID` |
| `source.run_url` | `$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID` |
| `source.tree_sha`, `source.ancestry[]` | **una** llamada `GET {api}/repos/{repo}/commits?sha=$GITHUB_SHA&per_page=100` con `GITHUB_TOKEN`: `tree_sha = [0].commit.tree.sha`, `ancestry = [{sha, at: commit.committer.date}]` (más nuevo primero, ≤ 100). Si `[0].sha != $GITHUB_SHA` o la llamada falla tras los reintentos: **no se envía** (aviso) |
| `source.actor` | **no existe** (C3). Gate T3: ningún script de telemetría referencia `github.actor`, `triggering_actor`, `GITHUB_ACTOR` ni `GITHUB_TRIGGERING_ACTOR` |
| `target.project` | `inputs.project` (slug; `validate-inputs` ya impone el patrón). Que sea el slug **global** del registro lo garantiza el caller (§9 Q2) |
| `target.environment` | `inputs.environment` **sin transformar** (ni minúsculas ni mapa): el colector normaliza |
| `target.cloud`, `.region`, `.kind` | `"aws"`, `inputs.aws-region`, `"aws-" + inputs.compute` (`aws-lambda`, `aws-ecs`, `aws-static`) |
| `target.service` | nombre del repo (`${GITHUB_REPOSITORY#*/}`): no hay un nombre de servicio estable común a los tres cómputos; el colector lleva el estado por repo, no por `service` |
| `artifact.image_tag` | solo `environment-deploy` con `image-tag` no vacío; si no, `artifact` se omite. `previous_image_tag` no se envía (ningún output lo expone) |
| `result.rollback` | `environment-deploy`: `image-tag != ''`; `cicd`: `false` |
| `result.circuit_breaker_triggered` | `false` siempre (limitación declarada, §9 Q5) |
| `result.status`, `result.failed_stage` | §3.4 |
| `stages.{gate,migration,deploy}` | §3.4; `duration_s = finished-at − started-at` del job (0 si se omitió) |
| `stages.migration.mode` | job omitido → `none`; ejecutado con `db-access=ssm-tunnel` → `ssm-tunnel`; `iam-direct` → **se omite `mode`** (el enum del colector no lo contempla y una mentira es peor que un hueco) |
| `timing.started_at` | `min(started-at)` de los stamps |
| `timing.finished_at` | `max(finished-at)` de los stamps (**no** `now`: así un reenvío posterior, §3.6, no infla el lead time). Sin stamps: `emitted_at` |
| `timing.commit_at` | `ancestry[0].at` |
| `timing.duration_s` | `finished_at − started_at` |
| `timing.lead_time_s` | **no existe** (C5) |

Ejemplo (valores ficticios) y esquema cerrado: `test/fixtures/telemetry/` (F0). El payload nunca contiene código, diffs, secretos, variables de entorno, logs ni personas.

### 3.4 Etapas y resultado

| Etapa del esquema | `lego-aws-cicd` | `lego-aws-environment-deploy` |
|---|---|---|
| `gate` | `quality-and-security-gate` | `quality-and-security-gate` |
| `migration` | `database-migration` | `database-migration` |
| `deploy` | `deploy` | `infra-deploy` **+** `post-deploy` (peor estado; duración = suma) |

- `stages.<x>.status`: el `result` del job (`success|failure|cancelled|skipped`).
- `result.status`: `cancelled` si alguna etapa lo está; si no `failure` si alguna falló; si no `success` (exige `deploy` en `success`: si no hay desenlace de deploy y nada falló, **no se emite**, con aviso).
- `result.failed_stage`: primera etapa en `failure` según el orden `gate → migration → deploy`; `null` en `success`/`cancelled`.
- **No se emite** cuando: `telemetry-url` o `telemetry-audience` vacíos (job omitido, cero minutos), `run-deploy=false`, o el evento es `pull_request` (un PR no es un despliegue).
- Limitación: con `migrate-before-deploy: true` la migración es un **paso** de `infra-deploy`, no un job; `stages.migration` queda `skipped`/`none` aunque se haya migrado.

### 3.5 Contrato del esquema

`contracts/telemetry.schema.json` es una copia del esquema del colector con `$id` y `description` neutralizados (el original nombra dominio y repos internos).
El **hash canónico** (`jq -cS 'del(."$id", .description)' | sha256sum`) vive en `contracts/telemetry.schema.sha256`; el gate T1 lo comprueba, y F0 deja evidencia de que
coincide con el esquema vigente del colector (lectura local). Cambiar un campo exige nueva `schema_version` **en los dos repos**. La validación del payload ocurre **en CI**
(fixtures de cada escenario contra el esquema con `ajv-cli`, versión fijada, solo en `self-ci`); en el runner del consumidor valida el colector (`422` con la ruta del campo).

### 3.6 Resiliencia y "reenvío"

- **Nunca rompe el pipeline** (doble red + una): `continue-on-error: true` en el **job** (el run no se pone rojo aunque el job falle por infraestructura) y en el paso;
  `timeout-minutes: 5` el job y `2` el paso (un timeout de paso con `continue-on-error` cuenta como éxito); `curl --connect-timeout 5 --max-time 10`; hasta 3 intentos solo ante
  `429`/`5xx`/fallo de red (los `4xx` definitivos no se reintentan); el script termina con `exit 0` pase lo que pase.
- **Qué hace con cada respuesta:** `202` aceptado y `200` duplicado = éxito; `401/403/422` = aviso con el `error.code` del colector y el `request_id` (nunca el token ni el cuerpo);
  `413/429/5xx`/red = aviso; en todos los casos que no son éxito se escribe `$TELEMETRY_DIR/telemetry-unsent.json` (por defecto `$RUNNER_TEMP/telemetry/`) y se imprime en el resumen.
- **Resumen del run** (`$GITHUB_STEP_SUMMARY`): estado HTTP, código del colector, `idempotency_key`, **`job_workflow_ref` y `job_workflow_sha` del token** (únicos claims que se imprimen)
  y el payload en un `<details>`. Es lo que cierra la verificación del valor real de `job_workflow_ref` en el colector (F6).
- **El reenvío no puede ser "el JSON, días después, desde otro run":** el colector exige que `run_id`, `run_attempt` e `idempotency_key` coincidan con los claims del token, y un token solo
  existe dentro de su run. Por eso el reenvío soportado es **"Re-run job → `telemetry-phone-home`"**: el job reconstruye el payload con el `run_attempt` nuevo y los stamps ya guardados
  en `needs` (`finished_at` no cambia), y el colector lo registra como un evento más. `telemetry-unsent.json` y el resumen quedan como **registro de lo que no llegó** (por eso no hay
  `upload-artifact`: un tercero dentro del job con `id-token: write` no compensa). Advertencia de runbook: re-ejecutar solo si el resumen dice que **no** se aceptó; si el original sí llegó, el
  intento 2 cuenta de nuevo (§9 Q4). Esto **contradice** lo que el spec del colector promete (§4.2/G7 "reenviar días después"): se le notifica (§9 Q1).

---

## 4. Guards de seguridad y el test que los hace cumplir

Los gates **recorren el árbol** (`find`/`yq`), fallan con 0 sujetos y se **verifican en rojo** (`test/bats/gates-red.bats`) antes de darlos por buenos. Ruta de los gates nuevos: `test/gates/dora-telemetry.bats`
(el G17 actual se **renombra con `git mv`** desde `dora-placeholder.bats`: sigue siendo G17, conserva su historial y deja de llamarse "placeholder"; veto posible, §9 Q8) y los bats de scripts.

| # | Guard | Test que lo hace cumplir | Rojo deliberado |
|---|---|---|---|
| **G17′** | Cada `lego-aws-*.yml` tiene **activo** `telemetry-phone-home`; no queda ningún `DORA-PLACEHOLDER`; inputs `telemetry-url` y `telemetry-audience` activos con `default: ""`; `needs` = **todos** los demás jobs (descubiertos por disco: un job futuro entra solo); `if` contiene `always()` y `inputs.telemetry-url != ''` y `inputs.telemetry-audience != ''` (y `inputs.run-deploy` si existe); `timeout-minutes ≤ 5`; contrato y workflow coinciden (G12) | `dora-telemetry.bats` | quitar un job de `needs`; borrar `always()`; dejar un marcador |
| **G2′** | `id-token: write` también en `telemetry-phone-home`, con `permissions == {contents: read, id-token: write}` | `permissions.bats` (+ cláusula en G17′) | añadir `pull-requests: write` o `actions: read` al job |
| **T0** | Sin secretos ni HMAC: `TELEMETRY_TOKEN`, `X-Signature`, `openssl dgst` no aparecen en `.github/`, `scripts/`, `contracts/` | `dora-telemetry.bats` | reintroducir el secret en el contrato |
| **T1** | El esquema es el del colector: hash canónico de `contracts/telemetry.schema.json` = `.sha256` | `telemetry-schema.bats` | editar un campo del esquema |
| **T2** | La audiencia no es libre: `^[a-z0-9][a-z0-9-]{2,62}$`; con la audiencia por defecto de AWS (`sts.amazonaws.com`), la de Azure (un URI con `:` y `/`), una URL, vacía o con mayúsculas/espacios/`&` **no se hace ninguna petición de token** (el `curl` falso registra 0 llamadas) | `test/bats/telemetry-send.bats` + `validate-inputs.bats` | permitir un `.` en la audiencia |
| **T3** | Sin tracking por persona: ningún `actor`/`triggering_actor` en los scripts y el composite de telemetría (descubiertos por glob) y el payload no lo contiene | `dora-telemetry.bats` + validación ajv | usar `GITHUB_ACTOR` en el builder |
| **T4** | Payload cerrado: cada escenario (success, failure en cada etapa, cancelled, rollback, static, `migrate-before-deploy`, `iam-direct`) valida contra el esquema; un fixture con campo extra (`actor`) y otro con `lead_time_s` **deben fallar** | `test/bats/telemetry-payload.bats` | añadir un campo al `jq -n` |
| **T5** | **Una** llamada a la API de commits, con `per_page=100`, `GITHUB_TOKEN` y sin checkout; `[0].sha != GITHUB_SHA` o 404/5xx ⇒ no se envía y el exit es 0 | `telemetry-fetch-commits.bats` (el `curl` falso cuenta llamadas) | segunda llamada |
| **T6** | El token no se filtra: `::add-mask::` antes del primer uso; ni stdout, ni el resumen, ni `telemetry-unsent.json`, ni outputs lo contienen; solo se imprimen `job_workflow_ref`/`job_workflow_sha` | `telemetry-send.bats` | `echo "$token"` |
| **T7** (era G7) | La telemetría nunca rompe: `curl` con 500, 4xx, timeout y fallo DNS ⇒ `exit 0` y `telemetry-unsent.json`; job y paso con `continue-on-error: true` | `telemetry-send.bats` + `dora-telemetry.bats` + `fail-hard.bats` ampliado al **nivel de job** | quitar `continue-on-error` del job |
| **T8** | El job de telemetría no ejecuta código del caller ni toca la nube: sin `checkout`, sin `run:`, sin `aws-oidc`/`configure-aws-credentials`/`azure/login`, único `uses` = composite interno | `dora-telemetry.bats` | añadir un `checkout` |
| **T9** | Los stamps existen: **todo** job de ambos workflows (salvo el de telemetría, que es el observador y tiene un único paso) declara los outputs `started-at`/`finished-at` y su último paso lleva `if: always()` | `dora-telemetry.bats` (por disco) | quitar un stamp |
| **T10** | Naming de release compatible con el colector: `release.yml` solo crea `vX.Y.Z` y `vX`; el patrón del colector acepta `v1`, `v1.2.0` y **rechaza** `v1.2`, `main` y un SHA | `test/gates/release-pins.bats` ampliado | aceptar `vX.Y` en `release.yml` |
| **T11** | `job_workflow_ref`/`version_ref` se extraen del token (fixtures: `@refs/tags/v1`, `@refs/tags/v1.2.0`, `@refs/heads/main`); con un token ilegible o sin esos claims **no se envía** | `telemetry-send.bats` | construirlos desde `GITHUB_WORKFLOW_REF` (es el del caller) |
| **T12** | `telemetry-url` exige el esquema `https`, sin credenciales embebidas ni espacios; el POST va a `${url%/}/v1/deployments` | `validate-inputs.bats` + `telemetry-send.bats` | aceptar el esquema `http` |
| **T13** | Ningún caller del sandbox pierde: todos conceden `id-token: write` (invariante de compatibilidad, §6) y existe un caller de telemetría con `@v1` y valores por `vars` | `dora-telemetry.bats` | quitar `id-token` de un caller |

Corolarios (por disco): descubrimiento ≥ 1 sujeto; excepciones declaradas dos veces (`docs/exceptions.yml`); G13 (nada interno) cubre composite, scripts, fixtures y este spec.

---

## 5. Decisiones y alternativas descartadas

| # | Decisión | Motivo | Descartado |
|---|---|---|---|
| D1 | Audiencia validada en el composite, no solo en `validate-inputs` | El job corre con `always()` aunque el gate falle | Confiar en el gate de inputs |
| D2 | Durations con **stamps por job** | No pide permisos nuevos al caller | API de jobs (`actions: read` ⇒ arranque fallido en callers existentes) |
| D3 | `workflow.*` leído **del token** | Un solo origen con lo que verifica el colector | `GITHUB_WORKFLOW_REF` (es el workflow del **caller**) |
| D4 | Sin `upload-artifact` | Un tercero en un job con `id-token: write` amplía la superficie | Artefacto de 7 días (SPEC §9.2) |
| D5 | Reenvío = re-run del job | Los claims atan el payload a su run | Reenviar el JSON desde otro run/terminal (403 por diseño) |
| D6 | Validación de esquema en CI, no en el runner | El runner no tiene validador; el colector ya responde 422 | Instalar `ajv` en cada run |
| D7 | `finished_at` = máximo de stamps | Reenvíos sin lead time inflado | `now` |
| D8 | `target.service` = nombre del repo | Sin nombre de servicio común a lambda/ecs/static | Nuevo input `telemetry-service` (se añade luego, aditivo, si hace falta) |
| D9 | `job` con `continue-on-error: true` | Un fallo de infraestructura del runner no pone rojo el run | Solo a nivel de paso |
| D10 | Renombrar el gate a `dora-telemetry.bats` con `git mv` | Un fichero "placeholder" sobre un job activo es deuda de conocimiento tácito | Mantener el nombre |
| D11 | `validate-inputs` **falla** ante un `telemetry-url`/`telemetry-audience` no vacío e inválido (con uno solo de los dos: aviso, telemetría apagada) | Es un error de configuración determinista, no un fallo del colector; y cierra el vector de §3.2 con ruido en vez de en silencio | Ignorarlo en silencio |
| D12 | `continue-on-error` y `timeout-minutes` del paso viven en el `uses` del workflow, no dentro del composite | El gate G-COE prohíbe `continue-on-error` en pasos de composites y el composite no admite `timeout-minutes`; los scripts ya terminan en `exit 0` | Ponerlos dentro del composite |

---

## 6. Versionado y llegada a los callers

- **Release `v1.2.0`** (minor): cambios **aditivos** — dos inputs opcionales con default `""`, un job nuevo y la salida interna de stamps. No cambia ningún `name:` de job existente (irreversible), ni inputs/outputs previos. Se crea **solo** con `release.yml` (`workflow_dispatch`, `version=1.2.0`); nunca a mano.
- **Llegada:** los callers en `@v1` reciben el cambio al moverse el alias. Sin `telemetry-url` **y** `telemetry-audience` el job se **omite** (cero minutos, cero llamadas): comportamiento idéntico al de `v1.1.1`. Un caller que quiera reportar añade los dos inputs (de `vars`) y ya.
  Los callers en `@v1.1.x` no cambian (los tags `vX.Y.Z` son inmutables).
- **Compatibilidad de permisos:** el job nuevo pide `contents: read` + `id-token: write`; un caller que no conceda `id-token` ya falla hoy en `deploy` (T13 lo deja como invariante). **No** se pide `actions`, `pull-requests` ni `checks` en el job nuevo.
- **`job_workflow_ref` y el patrón del colector:** el token del job de telemetría lleva `<org>/nextep-platform-workflows/.github/workflows/lego-aws-cicd.yml@refs/tags/v1` si el caller usa `@v1`. Por tanto:
  1. los callers **deben** usar `@v1` o `@vX.Y.Z`; con `@main`, un SHA o una rama el colector responde `403 workflow_not_allowed` (la telemetría se pierde con aviso; el pipeline sigue verde). `AGENTS.md` y el runbook lo dicen (F4);
  2. nunca se crean tags `vX.Y`, ni se renombran los `lego-*.yml` (T10);
  3. el valor **real** del claim (con `v1` móvil) se registra en F6 y se entrega a la sesión del colector, que ajusta su `allowed-workflows` si difiere.
- **Antes de liberar:** `git fetch --tags --prune` (el `v1` local está viejo), `main` empujada con `self-ci` verde, `RELEASE_TOKEN` vigente (verificar su caducidad) y el secret `INTERNAL_DENYLIST` presente (Q6/Q7).

---

## 7. Plan por fases

> Escrito para ejecución autónoma. **Una fase = un commit coherente**, en `main` (instrucción del mantenedor), sin push salvo la fase indicada. No se empieza la siguiente con la anterior en rojo.
> **Orden de cada fase: tests y gates primero, en rojo y verificados en rojo (se ve fallar con el mensaje nombrando el archivo), luego la implementación, luego verde.** Si la realidad contradice este spec, **se detiene y se actualiza el spec primero**.
> No se toca el repo del colector ni el del consumidor (se **leen**). Commits: `feat:`/`docs:`/`fix:`/`ref:` + inglés, imperativo, mayúscula inicial, sin punto final. Comandos para el humano en PowerShell; scripts del repo en bash.
> Suite local: `bats --recursive test/bats test/gates` (en Windows, con un `jq` que emita LF). Cada fase la corre completa.

### F0 — Spec aprobado y contrato del payload

- **Objetivo:** el esquema y los fixtures del payload viven en el repo, con su gate, antes de escribir un solo script.
- **Dependencias:** este spec aprobado. **Toca:** `docs/specs/telemetria-dora/SPEC.md` (estado → APROBADO), `contracts/telemetry.schema.json`, `contracts/telemetry.schema.sha256`, `test/fixtures/telemetry/**`, `test/gates/telemetry-schema.bats`, `scripts/lib/tools.env`, `scripts/ci/install-tools.sh` (ajv-cli fijado). **No toca:** workflows, composites, scripts de runtime, contratos de workflow.
- **Tareas:** (1) copiar el esquema de solo lectura desde el repo del colector, neutralizando `$id`/`description`; (2) calcular el hash canónico y guardarlo; (3) fixtures: un payload válido por escenario de T4 y dos inválidos (`actor`, `lead_time_s`); (4) `telemetry-schema.bats` (T1 + validación ajv de fixtures + los inválidos fallan); (5) instalar `ajv-cli` en `install-tools.sh`.
- **Pruebas unitarias obligatorias:** T1; fixtures válidos pasan; los dos inválidos fallan nombrando el campo.
- **Aceptación (PowerShell):** `bats test/gates/telemetry-schema.bats` → todo `ok`. Evidencia de sincronía: `jq -cS 'del(."$id", .description)' <ruta local al esquema del colector> | sha256sum` = contenido de `contracts/telemetry.schema.sha256`. **Rojo:** cambiar `"maxItems": 100` → el gate nombra `contracts/telemetry.schema.json`.
- **Rollback:** `git revert` del commit (solo añade ficheros).
- **Checkpoint:** `docs: Add the DORA telemetry spec and the payload schema contract`.

### F1 — Scripts de telemetría (fetch, build, send)

- **Objetivo:** los tres scripts, probados con `curl` falso, sin tocar un workflow.
- **Dependencias:** F0. **Toca:** `scripts/telemetry-fetch-commits.sh`, `scripts/telemetry-build-payload.sh`, `scripts/telemetry-send.sh`, `test/bats/fakes/curl` (ampliado y compatible: respuesta por ruta/host, `-w '%{http_code}'`, contador de llamadas), `test/bats/telemetry-*.bats`, `scripts/lib/common.sh` si hace falta. **No toca:** `.github/**`, contratos, `validate-inputs.sh`.
- **Tareas:** (1) bats en rojo (T2, T4, T5, T6, T7, T11, T12 + `shellcheck`); (2) `fetch-commits` (una llamada, `per_page=100`, valida `[0].sha`); (3) `build-payload` (`jq -n --arg`, tabla §3.3/§3.4, lee `needs-json` y claims decodificados del token); (4) `send` (petición del token con audiencia validada, `::add-mask::`, POST, política de respuestas §3.6, `telemetry-unsent.json`, resumen, `exit 0` siempre).
- **Pruebas unitarias obligatorias:** T2, T4, T5, T6, T7, T11, T12 (los de §4 marcados como "scripts"); reenvío: mismos `needs` con `run_attempt` 2 ⇒ mismo `finished_at`, clave distinta.
- **Integración en dev:** ninguna (sin red).
- **Aceptación:** `bats test/bats/telemetry-*.bats` verde y `shellcheck -x scripts/telemetry-*.sh` limpio. **Rojo:** hacer que `send` use `GITHUB_WORKFLOW_REF` para `workflow.name` → T11 falla nombrando el script; añadir una 2.ª llamada → T5 falla.
- **Rollback:** `git revert` (los scripts no están enganchados a nada).
- **Checkpoint:** `feat: Add the telemetry scripts (commits ancestry, payload builder and OIDC sender)`.

### F2 — Stamps de tiempo por job

- **Objetivo:** todo job de ambos workflows expone `started-at`/`finished-at`, sin cambiar su comportamiento.
- **Dependencias:** F1. **Toca:** `.github/workflows/lego-aws-cicd.yml`, `.github/workflows/lego-aws-environment-deploy.yml`, `test/gates/dora-telemetry.bats` (T9; el fichero nace aquí **con el G17 aún intacto** vía `git mv`). **No toca:** el bloque DORA, contratos, composites.
- **Tareas:** (1) T9 en rojo; (2) paso `Stamp the start` primero y `Stamp the end` (`if: always()`) último en cada job; outputs del job.
- **Pruebas unitarias obligatorias:** T9; `actionlint` limpio; G12 sigue verde (los outputs de job no son outputs del workflow).
- **Aceptación:** suite completa verde. **Rojo:** quitar un stamp → T9 nombra workflow y job.
- **Rollback:** `git revert`.
- **Checkpoint:** `feat: Stamp the start and end of every job for the telemetry timings`.

### F3 — Activación: composite, job, contratos y gates

- **Objetivo:** `telemetry-phone-home` activo en ambos workflows con todos los guards en verde.
- **Dependencias:** F2. **Toca:** `.github/actions/telemetry/action.yml`, ambos workflows (se **elimina** el bloque `DORA-PLACEHOLDER` y se añaden inputs y job), ambos contratos (inputs activos, `secrets: {}`, job en la lista), `scripts/validate-inputs.sh` (audiencia y URL, T2/T12), `test/gates/dora-telemetry.bats` (G17′, T0, T3, T7, T8, T13), `test/gates/permissions.bats` (G2′), `test/gates/fail-hard.bats` (nivel de job), `test/bats/gates-red.bats` (reescribir el caso "ACTIVE telemetry job" a "MISSING telemetry job" y añadir un rojo por invariante), `test/sandbox/callers/cicd-telemetry.yml`, `docs/exceptions.yml` solo si hubiera excepción. **No toca:** los jobs existentes (salvo lo de F2), `release.yml`, docs de adopción.
- **Tareas:** (1) gates actualizados y su rojo contra el árbol actual (ven el bloque comentado); (2) composite (pasos: validar audiencia/URL → fetch → build → send, todo con `continue-on-error` y `timeout-minutes`); (3) job con `needs` = todos los demás, `permissions` exactos, `continue-on-error` y `if` de §4; (4) contratos y `validate-inputs`; (5) caller de sandbox con `@v1` y `vars`.
- **Pruebas unitarias obligatorias:** G17′, G2′, G12, G3, G5, G11 (el composite no referencia otro composite), T0, T3, T7, T8, T13, T2/T12 en `validate-inputs.bats`; `actionlint` y `shellcheck` limpios; `release.sh` en seco sin referencias a `@main`.
- **Aceptación:** suite completa verde. **Rojos (cada uno nombra el archivo culpable):** añadir `pull-requests: write` al job, quitar un job de `needs`, añadir `actions/checkout`, reintroducir `TELEMETRY_TOKEN`, quitar `continue-on-error` del job, dejar un `DORA-PLACEHOLDER`.
- **Rollback:** `git revert` (vuelve el bloque comentado; ningún consumidor depende aún del `v1.2.0`).
- **Checkpoint:** `feat: Activate the telemetry-phone-home job with OIDC in both reusable workflows`.

### F4 — Documentación, ADR y runbook

- **Objetivo:** el repo dice lo mismo que hace el código.
- **Dependencias:** F3. **Toca:** `SPEC.md` (§0: enmienda "Telemetría"; §9 marcado **sustituido** con puntero a este spec; §6.5/G2 y §10/G7 enmendados), `AGENTS.md` (regla de `id-token`, `continue-on-error` en telemetría, callers por tag), `README.md` §3/§4, `docs/runbook.md` (colector caído, **reenvío = re-run del job**, alta de un consumidor, qué hacer ante `403 workflow_not_allowed`), `docs/adr/0004-telemetry-id-token-without-cloud-credentials.md` (decisión, audiencia, riesgo residual), este spec (§10 estado). **No toca:** código.
- **Pruebas unitarias obligatorias:** G13 sobre los docs; **T10** (`release-pins.bats`: el patrón del colector y las formas de tag de `release.yml`); un gate de coherencia por disco (`doc-coherence.bats`) (la regla de `id-token` de `AGENTS.md` y del gate G2 nombran los mismos jobs; `SPEC.md §9` no promete `TELEMETRY_TOKEN`).
- **Aceptación:** suite verde; `Select-String -Path README.md,AGENTS.md,SPEC.md -Pattern 'TELEMETRY_TOKEN'` solo aparece en el texto que declara el diseño anterior como sustituido.
- **Rollback:** `git revert`.
- **Checkpoint:** `docs: Document the OIDC telemetry flow, the id-token amendment and the resend procedure`.

### F5 — Release `v1.2.0` (acción de salida: requiere confirmación explícita)

- **Objetivo:** `v1.2.0` y `v1` apuntando al release commit, creados por `release.yml`.
- **Dependencias:** F4 en `main`; **Q6** (cómo llega `main` a `origin`) y **Q7** (`RELEASE_TOKEN`, `INTERNAL_DENYLIST`). **Toca:** nada en disco; operaciones remotas.
- **Tareas (PowerShell, las ejecuta el humano o el agente con su confirmación):** `git fetch --tags --prune`; push de `main`; esperar `self-ci` verde (`gh run watch`); `gh workflow run release.yml -f version=1.2.0`; `gh run watch`.
- **Aceptación:** `git ls-remote --tags origin 'v1*'` muestra `v1.2.0` y `v1` con el **mismo** objeto; `v1.1.1` intacto; `git show v1.2.0:.github/workflows/lego-aws-cicd.yml | Select-String 'telemetry-phone-home'` presente y sin `@main` interno.
- **Rollback:** nunca se mueve ni borra un tag publicado: se corrige con `v1.2.1`. Si el defecto es de seguridad, se retira el alias `v1` hacia `v1.1.1` con dos aprobadores (D4).
- **Checkpoint:** (no hay commit de código; el release commit lo crea `release.yml`).

### F6 — Aceptación real (coordinada con el primer consumidor)

- **Objetivo:** un run real `main → prod` del primer consumidor (carriles `[prod]`) con el paso de telemetría en `202` y el `job_workflow_ref` real registrado.
- **Dependencias:** F5; colector desplegado; la sesión del consumidor fija `telemetry-url` y `telemetry-audience` desde `vars` en su caller (`@v1`) y el registro del colector incluye su repo. **Toca:** solo este spec (§10, evidencia). **No toca:** repo del colector ni del consumidor desde esta sesión.
- **Tareas:** (1) entregar a la sesión del consumidor el texto de adopción (inputs, `@v1`, permisos); (2) tras el run, leer su resumen con `gh run view <id> --repo <org>/<repo> --log` (solo lectura): **HTTP 202**, `idempotency_key`, `job_workflow_ref` y `job_workflow_sha`; (3) copiar esos valores al §10 y entregárselos a la sesión del colector para cerrar su spike del claim; (4) segundo run: repetir el reenvío por re-run del job y comprobar `200`/`202` según el caso (verifica §3.6).
- **Aceptación:** el resumen muestra `202`; el claim real coincide con `lego-[a-z0-9-]+.yml@refs/tags/v1`, o se documenta la diferencia y se avisa al colector.
- **Rollback:** el consumidor quita los dos inputs (la telemetría se apaga sin tocar nada más) o fija `@v1.1.1`.
- **Checkpoint:** `docs: Record the real job_workflow_ref claim from the first reporting run`.

---

## 8. Riesgos y puntos irreversibles

**Irreversibles (se revisan una vez y bien):**

| Qué | Por qué | Mitigación |
|---|---|---|
| Nombres de inputs `telemetry-url`, `telemetry-audience` | API pública del reusable: renombrar = `v2` | Fijados en el contrato; G12 |
| Nombre del job `telemetry-phone-home` | Parte del nombre del check `<job-id> / telemetry-phone-home` | Fijado en el contrato; G12 |
| Forma del payload (`schema_version: 1.0`) | Los eventos históricos del colector la heredan | Esquema cerrado, T1; cambiar = versión nueva en ambos repos |
| Formato de `idempotency_key` y nombre de los `lego-*.yml` + convención de tags | Los verifica el colector; los claims los fija GitHub | T10; nunca `vX.Y`, nunca renombrar |
| `id-token: write` en un job nuevo | Un caller con menos permisos fallaría **al arrancar** | T13; ya es requisito de `deploy` |

**Corregibles después:** timeouts y reintentos, formato del resumen, `target.service`, `finished_at` (fórmula), nombres de los outputs de stamps (internos), plan B de ancestría (`git` en el gate).

| Riesgo | Impacto | Mitigación |
|---|---|---|
| Caller fija una audiencia cloud y un `telemetry-url` propio (§3.2) | Alto | T2 (composite + `validate-inputs`), enmascarado, ADR |
| Caller en `@main`/SHA ⇒ `403 workflow_not_allowed` | Medio (se pierde la métrica, el pipeline sigue) | Runbook, `AGENTS.md`, el resumen muestra el código |
| El colector exige `project` = slug global y el `project` del caller es un prefijo de recursos | Medio | §9 Q2: input opcional `telemetry-project` (aditivo) si aparece el caso |
| Un run que invoca el mismo workflow dos veces repite `idempotency_key` | Bajo | Segundo evento = duplicado (200); documentado (§9 Q3) |
| Re-run del job con el original ya aceptado ⇒ doble conteo | Medio | Runbook; propuesta al colector de deduplicar por `run_id` (§9 Q4) |
| La API de commits falla ⇒ no hay evento | Bajo | 3 intentos; aviso; plan B (ancestría con `git` en el gate) |
| +1 job por run con telemetría activa | Bajo | ≈ 20–40 s de runner; omitido sin los dos inputs |
| `v1` local viejo / `main` local por delante | Medio al liberar | §6 "Antes de liberar" |

---

## 9. Preguntas abiertas

| # | Pregunta | Bloquea | Propuesta |
|---|---|---|---|
| **Q1** | El spec del colector promete reenviar `telemetry-unsent.json` "días después" (§4.2/G7) pero su cruce body↔claims lo hace imposible desde otro run | — (aviso a la sesión del colector) | Reenvío = re-run del job (§3.6); el colector corrige su texto o añade dedupe por `run_id` |
| **Q2** | `project` es hoy prefijo de recursos del caller; el colector exige el slug global de su registro | — | Mismo valor; si difieren en algún repo, input opcional `telemetry-project` en un minor posterior |
| **Q3** | Clave de idempotencia sin sufijo: dos invocaciones del workflow en un run chocan | — | Documentar; el colector fija el patrón |
| **Q4** | Re-run con el original aceptado cuenta doble | — | Runbook + dedupe por `run_id` en el colector |
| **Q5** | `circuit_breaker_triggered` siempre `false` | — | Follow-up: que el composite ECS exponga el desenlace |
| **Q6** | ¿`main` admite push directo o debe ir por PR? | **F5** | **Resuelta (2026-11-12): push directo a `main`.** Se verifica en F5 |
| **Q7** | ¿`RELEASE_TOKEN` vigente y `INTERNAL_DENYLIST` configurado? | **F5** | **Resuelta: `INTERNAL_DENYLIST` ya está activo.** `RELEASE_TOKEN` se verifica en F5 con `gh secret list` |
| **Q8** | ¿Se renombra `dora-placeholder.bats` → `dora-telemetry.bats` (con `git mv`)? | F2 | **Resuelta: sí** |

---

## 10. Estado de ejecución y prompt para retomar

| Fase | Estado |
|---|---|
| Spec | **APROBADO** (2026-11-12) |
| F0 | **Hecha** (commit de esta fase) |
| F1 | **Hecha** (commit de esta fase) |
| F2 | **Hecha** (commit de esta fase; el gate se renombró a `dora-telemetry.bats`) |
| F3 | **Hecha** (commit de esta fase) |
| F4 | **Hecha** (commit de esta fase; incluye T10 y `doc-coherence.bats`) |
| F5 | **Hecha (2026-11-12)**: `v1.2.0` creado por `release.yml` (run 43279215413) sobre `main` = `707f1ed`; `v1` y `v1.2.0` apuntan al mismo tag object (commit `dc4fade`); `v1.1.1` intacto. El release incluye también el `compute: static` que `main` tenía sin publicar |
| F6 | **Pendiente** (necesita al primer consumidor y al colector desplegado; no se puede cerrar desde este repo) |

**Hand-off de F6 (texto para la sesión del primer consumidor; sin nombres internos):**

```text
Adopta telemetría en el caller del pipeline: el workflow por tag @v1 (ya es v1.2.0), y en el job que lo llama añade
  telemetry-url: ${{ vars.TELEMETRY_URL }}
  telemetry-audience: ${{ vars.TELEMETRY_AUDIENCE }}
con las dos variables de REPO fijadas (url https base del colector; audiencia = slug sin puntos que el colector espera).
Permisos del caller: los que ya tiene (id-token: write, contents: read, pull-requests: write); no hace falta nada más.
El repo debe estar en el registro del colector. Haz un run main -> prod y, en el resumen del job telemetry-phone-home, copia:
HTTP (esperado 202), idempotency_key, job_workflow_ref y job_workflow_sha. Entrégalos a quien cierra F6 (y a la sesión del colector).
Si el resumen dice 403 workflow_not_allowed, el caller no está en un tag; si dice repo_not_registered, falta el alta en el registro.
```

**Registro del claim real (F6):** _vacío_ — `job_workflow_ref`: …, `job_workflow_sha`: …, run: …, HTTP: …

**Prompt para retomar (copiar tal cual):**

```text
Lee AGENTS.md, SPEC.md §0, docs/specs/telemetria-dora/SPEC.md y test/gates/dora-telemetry.bats de nextep-platform-workflows. Si el spec está APROBADO, ejecuta la primera fase pendiente de §7 respetando "Toca / No toca":
tests y gates primero, en rojo y verificados en rojo; luego la implementación; una fase = un commit en main con el formato de §7.
Este repo es PÚBLICO: nada interno. No toques el repo del colector ni el del consumidor (solo lectura). No crees ni muevas tags a mano:
el release lo hace release.yml (F5, con confirmación). Si la realidad contradice el spec, detente y actualiza el spec primero.
Al cerrar cada fase, actualiza §10 (hecho, pendiente y este prompt).
```
