# SPEC — `lego-aws-image-publish`: construir y publicar una imagen en ECR por tag (release `v1.6.0`)

> Un reusable **nuevo y aditivo** que, al empujar un tag de versión en el repo del caller, construye la imagen, la sube a ECR con la etiqueta `X.Y.Z`
> y emite su **digest**. **Sin base de datos, sin bastión, sin deploy, sin telemetría.**
> **Estado: APROBADO (2026-11-20) v0.1** por el responsable del repo (viene de un spec de diseño de un consumidor, fase R1p). Ejecución en una fase (§6); estado en §8.
>
> **Este repo es PÚBLICO.** Aquí no hay nombres de proyectos, organizaciones, dominios ni cuentas internas. En los ejemplos:
> `example-org`, `shop`, `<ACCOUNT>`, `<REGION>`.

---

## 1. Problema y alcance

**Problema.** Un repo que **distribuye una imagen** (el consumidor la usa por digest desde otro repo) necesita publicarla por CI desde el primer día. Ningún reusable sirve (verificado leyendo el código, 2026-11-20):

1. `lego-aws-cicd` siempre migra la base por el bastión antes de desplegar y exige un servicio ECS al que hacer `force-new-deployment`.
2. `lego-aws-environment-deploy` es un deploy completo de ambiente, **solo manual** (`workflow_dispatch`), con infra y migración.
3. `scripts/build-push-image.sh` existe, pero solo vive dentro de esos dos flujos y etiqueta con el SHA del commit, no con una versión.

**Entra:**
- El workflow `lego-aws-image-publish`, su contrato, el composite `image-publish` y el script `scripts/image-publish.sh` (validar la entrada y el tag; leer el digest).
- Un parámetro **opcional y retrocompatible** `BUILD_PLATFORM` en `scripts/build-push-image.sh` (sin él, el comando de `docker build` no cambia byte a byte).
- Una **familia nueva de gates** `lego-aws-image-*` (por nombre, como la de paquetes), un ejemplo de política IAM del rol de publicación y un caller de sandbox.
- Documentación: README, runbook, AGENTS, SPEC.

**Queda fuera (explícito):**
- Desplegar la imagen en ningún servicio, migrar la base, o cualquier cosa de `lego-aws-cicd` / `lego-aws-environment-deploy` (no se tocan).
- `latest`, mutar etiquetas, o escaneo/firmado de la imagen (el escaneo lo hace el repo ECR al recibirla).
- Imágenes multi-arquitectura (una `platform` por run).
- Crear el repo ECR o el rol OIDC: los pone el consumidor (el rol **no** lo crea el pipeline que lo usa).

---

## 2. Diseño

### 2.1 Contrato

- **Disparo:** lo decide el caller: `push` de un tag `<tag-prefix>X.Y.Z`. El caller concede exactamente `permissions: { id-token: write, contents: read }`.
- **Entradas** (`contracts/lego-aws-image-publish.contract.yml`): `project` (obligatoria, `^[a-z][a-z0-9-]{1,15}$`), `ecr-repository` (obligatoria, nombre **literal**, sin plantillas), `role-arn` (obligatoria; **siempre desde `vars`, nunca literal**), `aws-region` (`us-east-2`), `dockerfile` (`Dockerfile`), `docker-context` (`.`), `platform` (`linux/amd64`; solo `linux/amd64` o `linux/arm64`), `tag-prefix` (`v`).
- **Secrets:** ninguno. **Salidas:** `version` (`X.Y.Z`), `image` (`<registro>/<repositorio>:<X.Y.Z>`) y `digest` (`sha256:<64 hex>`).
- **Un solo job, `publish`**, con permisos exactos `{contents: read, id-token: write}`. Su nombre y el del archivo son **irreversibles**: el `job_workflow_ref` de la trust policy del rol nombra el archivo y el tag del reusable.

### 2.2 Secuencia del job (el orden lo hace cumplir un gate)

1. checkout (`persist-credentials: false`);
2. **validar** la entrada y el disparo (sin credenciales): evento `push` de un **tag**, tag `^<tag-prefix>[0-9]+\.[0-9]+\.[0-9]+$`, `dockerfile`/`docker-context` relativos y sin `..`, el Dockerfile existe, `platform` permitida, `role-arn` con forma de ARN de rol (el valor nunca se imprime);
3. asumir el rol por OIDC (`aws-oidc`); login a ECR (`amazon-ecr-login`);
4. construir y empujar con `build-push-image.sh` (`IMAGE_TAG` = la versión, `ENVIRONMENT=release` para que **nunca** empuje `latest`);
5. leer el **digest** con `aws ecr describe-images --output json` y validarlo (`sha256:` + 64 hex);
6. resumen del run con `version`, `image` y `digest` listos para pegar en el archivo de datos del consumidor.

### 2.3 Decisiones (con motivo)

| Decisión | Motivo | Alternativa descartada |
|---|---|---|
| Etiqueta = solo `X.Y.Z` | Es la que el consumidor y el digest identifican; el repo ECR la hace inmutable | Etiquetar con el SHA (lo hace el deploy de ambiente) |
| Si la etiqueta ya existe **no se reconstruye**: se emite su digest y termina en verde | Un re-run tras un fallo parcial es seguro; las etiquetas son inmutables, así que el digest no puede cambiar | Fallar si existe (obliga a borrar a mano) o reconstruir (cambiaría el digest, que ECR rechazaría) |
| El digest sale de `describe-images`, no de la salida de `docker push` | Es la misma fuente que verificará el consumidor, y funciona también cuando no se empujó nada en este run | Parsear `docker push` |
| `ENVIRONMENT=release` hacia `build-push-image.sh` | El script solo añade `latest` si vale `dev`; reutilizarlo evita un segundo script de build | Duplicar el build en otro script |
| Un solo job con el rol asumido antes del build | Es lo que ya hace `infra-deploy`; `docker build` no hereda el entorno del runner. El script necesita el rol para comprobar si la etiqueta existe antes de construir | Dos jobs (gate sin rol + publish): sin nada que probar en el gate (no hay tests del caller) |
| Familia nueva `lego-aws-image-*` | Por defecto un `lego-aws-*` cae en la familia de **deploy** (telemetría, paridad, deploy-lock): estricta y equivocada. Se talla por nombre, como la de paquetes | Meterlo en la de deploy con excepciones |

---

## 3. Guards y su test

> Un guard sin test es prosa. Todos descubren sujetos **por disco** y fallan si no encuentran ninguno. **Verificados en rojo (§8).**

| # | Guard | Test | Dónde |
|---|---|---|---|
| G2 (ampliado) | `publish` puede tener `id-token: write` también en `lego-aws-image-*.yml`, y solo con permisos exactos `{contents: read, id-token: write}`; ningún otro job lo tiene | `test/gates/permissions.bats` | repo |
| G12 | El workflow coincide con su contrato (entradas, secrets, salidas, nombre del job) | `test/gates/contract-sync.bats` (existente) | repo |
| GI-F1 | Un solo job `publish`, sin `if:` ni `needs:`, con `concurrency` `image-publish-*` y `cancel-in-progress: false` | `test/gates/image-publish-flow.bats` | repo |
| GI-F2 | Orden: validar → `aws-oidc` → login a ECR → build/push → digest; **ningún comando del caller** corre antes de validar y la validación va **antes** del rol | `test/gates/image-publish-flow.bats` | repo |
| GI-F3 | Nunca `latest`: ni en el workflow, ni en el composite, ni `ENVIRONMENT` distinto de `release` hacia el build | `test/gates/image-publish-flow.bats` + bats del script | repo |
| GI-F4 | Los callers de sandbox disparan **solo** por `push.tags`, con permisos exactos `{id-token: write, contents: read}`, el reusable por tag y `role-arn` desde `vars` | `test/gates/image-publish-flow.bats` | repo |
| GI-F5 | El IAM de ejemplo: sin acción comodín, el push acotado a **un** repositorio, trust con `job_workflow_ref` del archivo por tag y `sub` acotado a un prefijo de tag, nunca una rama | `test/bats/iam-docs.bats` | repo |
| (existentes) | G3 acciones por SHA, G5 sin interpolación en `run:`, G10 sin inputs que debiliten, G11 composites sin referencias internas, G23 `ubuntu-latest`, GH5 sin cuenta como input | los gates de siempre, que descubren el archivo nuevo solos | repo |
| Familia | `lego-aws-image-*` **no** es de la familia de deploy: sin parity, telemetría ni deploy-lock | `gate_discover_deploy_workflows` la excluye por nombre; los gates de deploy siguen con sujetos | `test/gates/lib/gates.bash` |

---

## 4. Riesgos y puntos irreversibles

### 4.1 Irreversibles
- **El nombre del archivo y del job** (`lego-aws-image-publish.yml`, `publish`): quedan en la trust policy de cada rol de publicación.
- **El nombre de los inputs y de las salidas**: cambiarlos es una versión mayor.
- **La forma de la etiqueta** (`X.Y.Z`): los consumidores la fijan junto con el digest.

### 4.2 Corregibles
- La lista de plataformas permitidas; el texto del resumen.
- **Riesgo declarado, sin verificar:** el set exacto de acciones de ECR del rol de publicación sale de la documentación de AWS y no se ha ejercitado contra una cuenta real (§8).

---

## 5. Preguntas abiertas

| # | Pregunta | Bloquea | Propuesta |
|---|---|---|---|
| Q1 | ¿`image` debe llevar el ID de cuenta (va en el registro)? | Nada | Sí: sale del rol en ejecución, no es un literal del repo (GH5), y la salida solo la ve el repo del caller |
| Q2 | ¿Soportar `docker-target` y `build-args`? | Nada | No ahora: son entradas nuevas y aditivas el día que un consumidor las pida |

---

## 6. Plan por fases

### F1 — El reusable, su contrato, sus gates y su documentación *(una fase, un commit)*
- **Objetivo:** que un caller pueda publicar una imagen por tag y obtener su digest. **Dependencias:** ninguna.
- **Toca:** `.github/workflows/lego-aws-image-publish.yml`, `.github/actions/image-publish/action.yml`, `scripts/image-publish.sh`, `scripts/build-push-image.sh` (solo `BUILD_PLATFORM`), `contracts/lego-aws-image-publish.contract.yml`, `test/gates/lib/gates.bash`, `test/gates/permissions.bats`, `test/gates/image-publish-flow.bats`, `test/bats/image-publish.bats`, `test/bats/deploy-scripts.bats`, `test/bats/iam-docs.bats`, `test/bats/fakes/*`, `test/sandbox/callers/image-publish.yml`, `docs/iam/image-publish-*.example.json` y `README.md`, `docs/runbook.md`, `AGENTS.md`, `SPEC.md`, `docs/iam/README.md`. **No toca:** `lego-aws-cicd.yml`, `lego-aws-environment-deploy.yml`, los reusables de paquetes y de CI sin nube.
- **Tareas:** (1) spec (este archivo); (2) contrato; (3) script y bats con `aws`/`docker` falsos; (4) composite y workflow; (5) familia de gates y G2; (6) IAM de ejemplo y su test; (7) sandbox; (8) docs; (9) verificar cada gate en rojo y correr toda la suite.
- **Pruebas unitarias obligatorias:** los guards de §3, cada uno en rojo primero; bats del script (tag mal formado, etiqueta existente sin reconstruir y con digest, nunca `latest`, error de ECR distinto de «no existe», digest mal formado).
- **Aceptación:** `bats --recursive test/bats test/gates` verde; `actionlint` y `shellcheck` limpios. **Rollback:** no liberar el tag. **Checkpoint:** `feat: Add the image publish reusable workflow`.

---

## 7. Release

El tag lo crea **solo** `release.yml` (manual, desde `main`, empezando por `dry_run`): es una **característica nueva** (workflow y contrato nuevos, aditivos) ⇒ versión **menor**: se espera `v1.6.0`. El caller de un consumidor fija el tag exacto (`@v1.6.0`) para que el `job_workflow_ref` de su rol coincida.

---

## 8. Estado y retoma

- **Hecho:** F1 implementada en local (rama `feat/reusable-de-publicacion-de-imagen`, sin commit): ver el reporte de cierre. Se actualiza al liberar.
- **Prompt de retoma:** *«Lee `docs/specs/imagen-por-tag/SPEC.md` completo y ejecuta F1 (§6). Si la realidad contradice el spec, para y actualízalo primero. No crees ni muevas tags. Reporta Hecho / Verificado / No verificado / Brechas.»*
