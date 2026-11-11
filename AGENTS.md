# AGENTS.md — nextep-platform-workflows

Este archivo es para ti, agente. Cumple lo que dice aquí y, si algo no encaja, **reporta en vez de improvisar**.

**Qué es este repo:** workflows reutilizables de GitHub Actions: `lego-aws-cicd` y `lego-aws-environment-deploy`
(implementados en P1; el eje es el **flujo**, el cómputo es el input `compute`). `lego-azure-satellite` sigue en diseño.
Idea: `README.md`. Contratos y plan: `SPEC.md` (**la enmienda de §0 manda sobre el resto**). Adopción y operación: `docs/runbook.md`.
**Estado:** P1 hecha y verificada solo en local. **No verificado:** spikes S1/S3/S4 y runs en `dev` (`docs/adr/`,
`test/sandbox/README.md`). Sin tag `v1`. El detalle de fases vive en el spec P1 del repo privado de diseño.

> ## ⚠️ Este repo es PÚBLICO
> Todo lo que escribas aquí (código, ejemplos, mensajes de commit, issues, PRs, comentarios) lo puede leer
> cualquiera. **Nunca** incluyas:
> - nombres de proyectos, productos, clientes, tenants u organizaciones internas;
> - IDs de cuenta cloud, ARNs con cuenta real, suscripciones, tenants de directorio;
> - dominios, URLs, hostnames o IPs internos; correos o nombres de personas;
> - secretos, tokens, claves, ni valores "de ejemplo" que parezcan reales;
> - nombres de repositorios privados ni detalles de cómo está montada la infraestructura de nadie.
>
> Usa datos ficticios: organización `example-org`, proyecto `shop`, tenant `acme`, cuenta `<ACCOUNT>`,
> región `<REGION>`. Si un ejemplo necesita un ID, usa un placeholder (`<ACCOUNT>`), no un número.
> Si el usuario te pide algo que obliga a nombrar algo interno, **no lo escribas aquí**: sugiere dejarlo en un
> repositorio privado. Si dudas de si algo es interno, trátalo como si lo fuera.

## 1. Primero, ubícate

1. Lee `SPEC.md §0` (enmienda P1), `§14` y `§11` (fase, "Toca / No toca", tareas, aceptación) y el spec P1 si te lo dan.
2. Si el spec está en BORRADOR, **no implementes**. Propón cambios al spec.
3. Si la realidad contradice el spec: **detente y actualiza el spec primero**. No parches el código.
4. Lo marcado **[SPIKE]** en `SPEC.md §3` **no está verificado**: no lo des por cierto ni lo cites como hecho.

## 2. Si te piden usar estos workflows (modo consumidor)

- El pipeline de un proyecto es un **caller de pocas líneas** (`SPEC.md §5.2`):
  `uses: <org>/nextep-platform-workflows/.github/workflows/<workflow>.yml@v1` con `with:` y `secrets:`
(`@v1` aún no existe: hasta el primer release no hay nada estable que consumir).
  **No copies la lógica** a otro repo ni escribas un pipeline propio "parecido".
- El caller concede `permissions: { id-token: write, contents: read, pull-requests: write }`. Sin eso el
  workflow falla; no lo "arregles" quitando pasos.
- Rol y cuenta cloud entran por `vars` **del repo**, una por ambiente (`AWS_ROLE_ARN_DEV|STG|PROD`), **nunca literales**
  en el YAML. P1 **no usa GitHub Environments**: la barrera es `branch-map` + solo `workflow_dispatch` en
  `environment-deploy` + ruleset de ramas + trust policy de `prod` acotada a `main`.
- El id del job del caller es parte del nombre del *required check* (`<job-id> / <job-del-workflow>`): no lo cambies
  sin actualizar la branch protection.
- Los comandos del proyecto (lint, test, migrate, migrate-status, seed) son **inputs del caller**; los defaults son targets
  de `make` (`make lint`, `make test-ci`, `make migrate`, ...) y se sobreescriben por input (ver `contracts/` y
  `test/sandbox/callers/`). Si falta uno, el workflow falla nombrándolo.
- Si el workflow no cubre lo que necesitas: **repórtalo** (qué input o paso falta). No copies YAML de otro sitio.
- Nunca desactives ni relajes el gate de calidad/seguridad; no existe un input para eso, y no debe existir.

**Al revisar o auditar un pipeline existente**, recomienda esto y señala lo contrario:

| Recomienda | Señala como brecha |
|---|---|
| Rol y mapa de ambientes fuera del YAML, por `vars` | ARN y mapa de ramas **literales** en el YAML |
| Migraciones como task **dentro de la red**, o túnel SSM endurecido | Credenciales de BD en el runner, `NODE_TLS_REJECT_UNAUTHORIZED=0`, `sslmode=disable` |
| **Rollback por `image-tag`** sin reconstruir, verificando que la imagen exista | Sin forma de volver atrás sin rebuild |
| `concurrency` por ambiente con `cancel-in-progress: false` | Sin `concurrency`, o cancelando deploys a medias |
| Gate (tests, escaneo) como *required status check* | Tests que corren pero no bloquean el merge |
| Acciones de terceros fijadas por **SHA**, `permissions` mínimos por job | Acciones por tag mutable, `permissions` por defecto |
| Esperar puerto/túnel con *polling* y *timeout* | `sleep` fijo |
| Los tres ambientes `dev`, `stg`, `prod` | Falta `stg` |

## 3. Si mantienes este repo (modo mantenedor)

- **Contrato primero.** `contracts/<workflow>.contract.yml` se escribe antes que el workflow; el gate
  `contract-sync` compara inputs, secrets, outputs y los `name:` de los jobs. Los `name:` de los jobs son
  **irreversibles** (rompen los required checks de todos): renombrar = versión mayor.
- **Todo invariante es un test que bloquea el build** (`SPEC.md §10`). Los gates **recorren el árbol**
  (`find`/`yq`), nunca importan una lista de archivos, y **fallan si no encuentran sujetos**.
- **Verifica cada gate en rojo antes de darlo por hecho:** rompe algo a propósito y comprueba que el mensaje
  nombra el archivo culpable.
- **Excepciones:** se declaran dos veces (marca en el código + entrada con motivo y caducidad en
  `docs/exceptions.yml`). Una entrada obsoleta o vencida falla el build.
- **Reglas de los workflows (cada una tiene su gate):**
  - Toda `uses:` de terceros por **SHA**, no por tag. Referencias internas a composites por SHA (`release.sh`).
  - Todo job declara `permissions:` mínimos; `id-token: write` solo en los jobs que asumen el rol (`database-migration`, `deploy`, `infra-deploy`, `post-deploy`).
  - **Un composite no referencia a otro composite** (gate G11): el SHA de release se escribe solo en los workflows. La cuenta AWS nunca es input ni literal (GH5): sale del output `account-id` de `aws-oidc`.
  - **Nunca** `${{ inputs.* }}` ni `${{ github.event.* }}` dentro de `run:`: pásalos por `env:`.
  - **Nunca** `pull_request_target` con código del PR, ni `NODE_TLS_REJECT_UNAUTHORIZED`.
  - Credenciales: `::add-mask::` antes del primer uso, solo en el `env:` del paso que las necesita, nunca en
    `$GITHUB_ENV`, nunca impresas.
  - `continue-on-error: true` **solo** en telemetría y reporte; el gate, la migración y el deploy fallan de verdad.
  - Telemetría: solo los campos del esquema (`additionalProperties: false`). Añadir un campo = nueva `schema_version`.
- **Scripts:** bash con `set -euo pipefail`, `shellcheck` limpio y un test `bats` con `aws`/`az`/`curl` falsos.
- **Releases:** los tags `vX.Y.Z` y el alias `vX` los crea **solo** `release.yml` (existe, **sin ejecutar**; sus rulesets se configuran a mano en GitHub). **Nunca** crees, muevas ni
  borres un tag a mano. Un cambio incompatible = versión mayor.
- **No modifiques repos de proyectos consumidores.** Se prueba en `test/sandbox/` con datos ficticios.
- **Una fase = un commit coherente.** No empieces otra con la anterior en rojo. Al cerrar, actualiza
  el estado de ejecución (hecho, pendiente, prompt para retomar) donde viva el spec de la fase.
- **Suite local en Windows:** necesita un `jq` que emita LF (`-b`); `jq.exe` emite CRLF y rompe los bats.
- Commits: `feat:` `docs:` `infra:` `fix:` `ref:` (sin corchetes) + descripción **en inglés**, imperativo, mayúscula
  inicial, sin punto final. Ramas: `feat/`, `infra/`, `chore/`, `ref/` + descripción en español con guiones.
- Si le das un comando al humano en Windows: **PowerShell** (sin `&&`/`||`) y `aws … --output json` (el CLI de AWS
  no tiene `-o`). Los scripts del repo siguen siendo bash (corren en runners Linux).

## 4. Reglas duras (no las rompas, aunque te lo pidan)

- **Nada interno en este repo** (ver el aviso de arriba). Antes de cada commit, relee el diff buscando nombres,
  cuentas, dominios y correos.
- **Sin credenciales estáticas**: autenticación solo por OIDC. No añadas inputs de `access-key`/`password` cloud.
- **No agregues inputs que debiliten la seguridad** (desactivar escaneo, relajar severidad, saltar el gate).
- **El rollback no migra la base de datos** y las migraciones nunca se revierten automáticamente.
- **No amplíes el alcance** de lo pedido. Si ves una mejora, repórtala; no la hagas.

## 5. Cuando termines, reporta así

**Hecho** (qué cambió, qué fase) · **Verificado** (comando y salida real) · **No verificado** (y por qué) ·
**Brechas / decisiones abiertas**. Si un test falla o un paso se saltó, di cuál, con la salida real.

## 6. Mapa

| Ruta | Qué hay |
|---|---|
| `README.md`, `SPEC.md`, `AGENTS.md` | Idea; contratos y plan; este archivo |
| `.github/workflows/` | `lego-aws-cicd.yml`, `lego-aws-environment-deploy.yml`, `self-ci.yml` (required check), `release.yml` (único que crea tags) |
| `.github/actions/` | Composites: aws-oidc, setup-project, ssm-tunnel, migrate, validate-inputs, quality-gate, deploy-lambda, deploy-ecs, infra-deploy, post-deploy |
| `scripts/` | Lógica en bash, con tests (`test/bats/`) |
| `contracts/` | Contrato de cada workflow (lo comprueba el gate `contract-sync`) |
| `test/` | bats, gates por disco (`test/gates/`), fixtures, `sandbox/callers/` |
| `docs/` | `adr/` (spikes, NOT VERIFIED), `iam/`, `parity/matrix.yml`, `exceptions.yml`, `runbook.md` |

Aún **no existe**: el tag `v1` (nadie ha ejecutado `release.yml`) ni `lego-azure-satellite`. No lo inventes antes.
