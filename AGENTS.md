# AGENTS.md — nextep-platform-workflows

Este archivo es para ti, agente. Cumple lo que dice aquí y, si algo no encaja, **reporta en vez de improvisar**.

**Qué es este repo:** workflows reutilizables de GitHub Actions (`lego-aws-ecs`, `lego-aws-lambda`,
`lego-azure-satellite`). Idea: `README.md`. Contratos y plan: `SPEC.md`.
**Estado:** diseño. Lo vigente es `SPEC.md §11` (fases) y `§14` (estado).

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

1. Lee `SPEC.md §14` (qué fase toca) y `§11` (la fase: "Toca / No toca", tareas, aceptación).
2. Si el spec está en BORRADOR, **no implementes**. Propón cambios al spec.
3. Si la realidad contradice el spec: **detente y actualiza el spec primero**. No parches el código.
4. Lo marcado **[SPIKE]** en `SPEC.md §3` **no está verificado**: no lo des por cierto ni lo cites como hecho.

## 2. Si te piden usar estos workflows (modo consumidor)

- El pipeline de un proyecto es un **caller de pocas líneas** (`SPEC.md §5.2`):
  `uses: <org>/nextep-platform-workflows/.github/workflows/<workflow>.yml@v1` con `with:` y `secrets:`.
  **No copies la lógica** a otro repo ni escribas un pipeline propio "parecido".
- El caller concede `permissions: { id-token: write, contents: read, pull-requests: write }`. Sin eso el
  workflow falla; no lo "arregles" quitando pasos.
- Rol y cuenta cloud entran por `vars` del GitHub Environment (`${{ vars.… }}`), **nunca literales** en el YAML.
- El id del job del caller es parte del nombre del *required check* (`<job-id> / <job-del-workflow>`): no lo cambies
  sin actualizar la branch protection.
- El proyecto debe exponer los targets de `make` del contrato (`lint`, `test-ci`, `migrate`, `migrate-status`,
  y `build` si aplica). Si faltan, el gate falla nombrando el target: añádelo en el proyecto.
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
  - Todo job declara `permissions:` mínimos; `id-token: write` solo en `database-migration` y `deploy`.
  - **Nunca** `${{ inputs.* }}` ni `${{ github.event.* }}` dentro de `run:`: pásalos por `env:`.
  - **Nunca** `pull_request_target` con código del PR, ni `NODE_TLS_REJECT_UNAUTHORIZED`.
  - Credenciales: `::add-mask::` antes del primer uso, solo en el `env:` del paso que las necesita, nunca en
    `$GITHUB_ENV`, nunca impresas.
  - `continue-on-error: true` **solo** en telemetría y reporte; el gate, la migración y el deploy fallan de verdad.
  - Telemetría: solo los campos del esquema (`additionalProperties: false`). Añadir un campo = nueva `schema_version`.
- **Scripts:** bash con `set -euo pipefail`, `shellcheck` limpio y un test `bats` con `aws`/`az`/`curl` falsos.
- **Releases:** los tags `vX.Y.Z` y el alias `vX` los crea **solo** `release.yml`. **Nunca** crees, muevas ni
  borres un tag a mano. Un cambio incompatible = versión mayor.
- **No modifiques repos de proyectos consumidores.** Se prueba en `test/sandbox/` con datos ficticios.
- **Una fase = un commit coherente.** No empieces otra con la anterior en rojo. Al cerrar, actualiza
  `SPEC.md §14` (hecho, pendiente, prompt para retomar).
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
| `.github/workflows/lego-*.yml` 🚧F1–F3 | Los workflows reutilizables |
| `.github/actions/` 🚧F1 | Composites internos (referenciados por SHA) |
| `scripts/` 🚧F1–F2 | Lógica en bash, con tests |
| `contracts/` 🚧F1 | Contratos máquina-legibles y esquema de telemetría |
| `test/` 🚧F0 | bats, gates por disco, fixtures, sandbox |
| `docs/` 🚧F0 | ADRs de los spikes, ejemplos de IAM, runbook |

🚧 = aún no existe; se crea en la fase indicada. No lo inventes antes.
