# SPEC — Toolchain de Python y etapa de base de datos opcional (release `v1.3.0`)

> Dos cambios **aditivos** a `lego-aws-cicd` y `lego-aws-environment-deploy`: (A) un toolchain de Python en `setup-project`,
> para repos cuyas migraciones, lint y tests corren con `pip`; (B) un input `migrate` para que un servicio de `compute: ecs`
> **sin base de datos** use `lego-aws-environment-deploy` sin pasar por la etapa de migración.
> **Estado: APROBADO (2026-11-16) v0.2 — Q1 y Q2 resueltas (§9). Ejecución fase por fase (§7); estado en §10.**
>
> **Este repo es PÚBLICO.** Aquí no hay nombres de proyectos, organizaciones, dominios ni cuentas internas. En los ejemplos:
> `example-org`, `shop`, `<ACCOUNT>`, `<REGION>`.

| | |
|---|---|
| **Versión del spec** | 0.2.0 (2026-11-16) — aprobado |
| **Aprobador** | Mantenedores del repo (`.github/CODEOWNERS`); aprobado el 2026-11-16 con las recomendaciones de Q1 y Q2 |
| **Ejecutor previsto** | Agente autónomo, fase por fase (§7), o un DevOps sin contexto de la conversación |
| **Release objetivo** | `v1.3.0` (minor, aditivo, §6); el alias `v1` se mueve solo por `release.yml` |
| **Preguntas abiertas** | §9 (Q1 y Q2 resueltas; Q3 no bloquea) |

---

## 1. Problema y alcance

**Problema.** Un consumidor con tres servicios `compute: ecs` (dos APIs en Python con migraciones `alembic` y un front en Next.js,
cada uno en su repo) choca con dos límites de la plantilla, ambos verificados leyendo el código (2026-11-16):

1. **No hay toolchain de Python.** `setup-project` instala Node y un gestor de paquetes de Node (`pnpm` o `npm`) y nada más. Los comandos del
   caller (`lint-command`, `test-command`, `migration-command`, `migration-verify-command`) corren en el mismo runner, pero un `alembic` o un
   `pytest` no existen ahí salvo por lo que traiga la imagen del runner, sin versión fijada ni caché. Hoy se resolvería con un `pip install`
   dentro de `migration-pre-command` (un hook que la propia plantilla marca como deuda): sin pin, sin caché y solo en la etapa de migración.
2. **Un servicio sin base de datos no puede usar `lego-aws-environment-deploy` con `compute: ecs`.** `validate-inputs.sh` marca `migrates=true`
   cuando `compute != static` y no hay `image-tag`, y entonces exige `bastion-id-ssm-param`, `db-endpoint-ssm-param`, `db-secret-id` y `db-name`.
   `compute: static` evita la etapa, pero ese modo no construye imagen. `lego-aws-cicd` no tiene el problema (solo migra si hay bastión).

**Entra:**
- (A) Inputs `python-version` y `python-requirements` en ambos workflows, y su implementación en el composite `setup-project`.
- (B) Input `migrate` (boolean) en `lego-aws-environment-deploy`.
- Gates por disco de cada invariante, contratos, matriz de paridad, documentación, sandbox y el release `v1.3.0`.

**Queda fuera (explícito):**
- Un `compute: python` o cualquier cambio del eje del workflow (el eje sigue siendo el **flujo**; el cómputo es un input).
- Gestores de Python distintos de `pip` (`uv`, `poetry`, `pipenv`): se pueden añadir después como valor de un input nuevo sin romper nada.
- El modo `register-task-definition` del deploy de ECS (hoy solo `force-new-deployment`): es otro spec.
- Cambiar cómo se arma `DATABASE_URL` o el TLS de la conexión (`PGSSLMODE` y similares): lo decide el comando del caller; este spec no lo toca.
- Escaneo de dependencias (`pip-audit`): es la etapa 2 del gate de calidad.
- Tocar repos consumidores (se prueba en `test/sandbox/` con datos ficticios).

---

## 2. Estado de partida (verificado en disco, 2026-11-16)

| Hecho | Evidencia |
|---|---|
| `setup-project` solo conoce Node y `npm|pnpm` | `.github/actions/setup-project/action.yml` (pasos: `pnpm/action-setup`, `setup-node`, `install-dirs.sh install`) |
| Lo llaman 7 pasos: 3 en `lego-aws-cicd`, 4 en `lego-aws-environment-deploy` | `grep -n setup-project .github/workflows/*.yml` |
| `install-dirs.sh` exige `package.json` y lockfile en cada raíz | `scripts/install-dirs.sh` |
| `migrates=true` si `environment-deploy`, sin `image-tag` y `compute != static` | `scripts/validate-inputs.sh` (bloque «compute-specific requirements») |
| `compute: static` apaga la etapa con la cadena `inputs.compute != 'static'` en 4 sitios del workflow | `lego-aws-environment-deploy.yml` (pasos del túnel/migración de `infra-deploy`, job `database-migration`, job `post-deploy`, paso de post-deploy dentro de `infra-deploy`), gate `test/gates/static-compute.bats` |
| `test-database-image` entrega `TEST_DATABASE_URL` con esquema `postgresql://` | `scripts/test-postgres.sh` |
| El runner expone `PGSSLROOTCERT` y `NODE_EXTRA_CA_CERTS` a los comandos de BD, no `PGSSLMODE` | `scripts/run-migration.sh` (`run_db`) |

---

## 3. Diseño

### 3.1 (A) Toolchain de Python

**Contrato (ambos workflows y `setup-project`):**

| Input | Tipo | Default | Regla |
|---|---|---|---|
| `python-version` | string | `""` | Vacío = no se instala Python. Formato `^3\.[0-9]{1,2}(\.[0-9]{1,2})?$` (`3.12` o `3.12.7`). |
| `python-requirements` | string | `""` | Rutas relativas, separadas por coma, de archivos de dependencias (`requirements.txt,requirements-dev.txt`), en el orden de instalación. Mismas reglas de ruta que `install-dirs` (sin `..`, sin espacios, sin `/` final) y deben ser archivos. |

- **Todo o nada:** `python-version` sin `python-requirements` falla; `python-requirements` sin `python-version` falla. Una versión sin
  dependencias no es un proyecto, es un descuido.
- **En `setup-project`**, después del paso de Node y solo si `python-version != ''`: `actions/setup-python` (por SHA) con `python-version`,
  `cache: pip` y `cache-dependency-path` = los archivos de `python-requirements`; luego `scripts/python-install.sh`. Node **sigue** instalándose
  siempre: un repo con `infra/` en CDK necesita Node aunque su aplicación sea Python.
- **`scripts/python-install.sh`** (bash, `set -euo pipefail`, `shellcheck` limpio, test `bats` con un `pip` falso):
  1. **Valida cada archivo antes de instalar nada.** Se aceptan: comentarios, líneas en blanco, `-r <archivo>` / `-c <archivo>` (relativos, dentro del repo,
     profundidad ≤ 3, también validados) y requisitos **fijados**: `nombre==versión` (con extras y marcadores de entorno permitidos) o con `--hash=`.
     Se rechazan, nombrando archivo y línea: rangos (`>=`, `<=`, `~=`, `>`, `<`, `!=`), requisitos sin versión, `-e`, URLs y VCS (`git+…`),
     y las opciones de origen (`--index-url`, `--extra-index-url`, `--find-links`, `--trusted-host`).
     *Motivo:* es el equivalente de `--frozen-lockfile` para pip. Un rango hace que dos corridas del mismo commit instalen cosas distintas;
     `--extra-index-url` es el vector clásico de *dependency confusion*.
  2. Instala cada archivo en orden con `python -m pip install --no-input --disable-pip-version-check -r <archivo>`. Si el archivo trae hashes,
     pip los exige por sí mismo (modo `--require-hashes`).
  3. No crea un `venv`: el runner es efímero y los comandos del caller encuentran `python`, `alembic` y `pytest` en el `PATH`.
- Los 7 pasos que llaman a `setup-project` pasan los dos inputs nuevos (si no, la migración o el lint del job que olvidó pasarlos corre sin Python).

**Lo que NO cambia:** `test-database-image` sigue entregando `postgresql://…`. Adaptarlo a un dialecto con driver (`postgresql+asyncpg://`) es del comando
del caller (por ejemplo, sustituir el prefijo con expansión de variables de bash). Un input para eso sería una caída por la pendiente resbaladiza de «otro
dialecto, otro input».

### 3.2 (B) Etapa de base de datos opcional (`migrate`)

**Contrato (solo `lego-aws-environment-deploy`):**

| Input | Tipo | Default | Regla |
|---|---|---|---|
| `migrate` | boolean | `true` | `false` apaga **toda** la etapa de base de datos para `compute: ecs` o `lambda`. |

- **Default `true` = comportamiento idéntico a `v1.2.0`.** Ningún caller existente cambia.
- **Con `migrate: false`:**
  - `validate-inputs.sh` **rechaza** los inputs que quedarían como configuración muerta, igual que hoy con `compute: static`: `bastion-id-ssm-param`,
    `db-endpoint-ssm-param`, `db-secret-id`, `db-name`, `db-schema`, `migration-pre-command`, `post-migrate-command` no vacíos; `db-access: iam-direct`;
    `migrate-before-deploy: true`; y `migration-command` / `migration-verify-command` distintos de su default. Un caller no arrastra configuración que parece hacer algo.
  - No se levanta túnel, no se llama a `migrate`, no corre el job `database-migration`.
  - El `post-deploy-command` corre **dentro de `infra-deploy`** (mismo runner, mismo rol), como en `compute: static`, y el job `post-deploy` se omite.
  - El rollback por `image-tag` no cambia (ya no migra nunca).
- **`compute: static` ignora `migrate`** (no tiene etapa de BD; el default `true` no debe fallar con él). Sus reglas actuales no se tocan.
- **Cómo se implementa sin renombrar nada:** las cuatro condiciones que hoy dicen `inputs.compute != 'static'` pasan a
  `inputs.compute != 'static' && inputs.migrate`, y la del paso de post-deploy dentro de `infra-deploy` pasa a
  `(inputs.migrate-before-deploy || inputs.compute == 'static' || !inputs.migrate)`. Ningún `name:` de job cambia (irreversible, §8).
- **Telemetría:** con la migración omitida el job `database-migration` queda `skipped`, igual que en `compute: static` y en rollback; el payload ya
  contempla ese resultado. F2 lo verifica con el escenario existente; no se añade ningún campo al esquema.

### 3.3 Qué se descarta y por qué (una línea cada una)

- **Inferir «sin BD» de que los inputs `db-*` estén vacíos:** hoy esa omisión es un error útil («falta `db-name`»); inferirlo lo convierte en un salto silencioso. Es explícito o no es.
- **Instalar Python dentro de `migration-pre-command`:** sin pin, sin caché, solo en un job, y refuerza un hook que ya se declaró deuda.
- **Aceptar rangos en `python-requirements`:** instala cosas distintas según el día; contradice «install inmutable» de la plantilla. Ver Q1.
- **Un `compute: python` o `compute: ecs-nodb`:** multiplica los valores del eje en vez de aislar la variación en un input.
- **Poner `migrate` también en `lego-aws-cicd`:** allí la etapa ya es opcional (solo corre si hay `bastion-id-ssm-param`); duplicar el mecanismo es ruido.

---

## 4. Guards y el test que los hace cumplir

> Regla del repo: un guard sin test es prosa. Los gates **recorren el árbol**, **fallan si no encuentran sujetos** y se **verifican en rojo** antes de darlos por buenos.

| ID | Guard | Test que lo hace cumplir |
|---|---|---|
| G-PY1 | `python-version` solo acepta `3.N` o `3.N.P`; cualquier otra cosa falla nombrando el input | `test/bats/validate-inputs-python.bats` |
| G-PY2 | `python-version` y `python-requirements` van juntos; las rutas cumplen las reglas de `install-dirs` (sin `..`, sin espacios, sin `/` final) | `test/bats/validate-inputs-python.bats` |
| G-PY3 | `python-install.sh` rechaza rangos, requisitos sin versión, `-e`, URLs/VCS y opciones de origen, **nombrando archivo y línea**; acepta pins, hashes y `-r` anidados válidos; el `-r` fuera del repo o con ciclo falla | `test/bats/python-install.bats` (con `pip` falso en el `PATH`) |
| G-PY4 | **Por disco:** todo paso `uses: …/setup-project@…` de todo workflow en `.github/workflows/` pasa `python-version` y `python-requirements` (descubre los pasos con `yq`; falla si encuentra 0) | `test/gates/python-toolchain.bats` |
| G-PY5 | `actions/setup-python` fijada por **SHA** con comentario de versión | `test/gates/pinned-actions.bats` (existente: debe cubrirlo sin cambios; si no, se extiende) |
| G-DB1 | Con `migrate: false`, cada input de la lista de §3.2 no vacío (o con valor no default) falla nombrando el input; con `compute: static` y `migrate: true` (default) **no** falla | `test/bats/validate-inputs-migrate.bats` |
| G-DB2 | **Por disco:** en todo workflow con el input `migrate-before-deploy`, el paso del túnel, el paso `migrate`, el job `database-migration` y el job `post-deploy` contienen `inputs.migrate` en su `if:`, y el paso de post-deploy de `infra-deploy` contiene `!inputs.migrate` (falla si encuentra < 4 sujetos) | `test/gates/skip-database-stage.bats` (hermano de `static-compute.bats`) |
| G-DB3 | Compatibilidad: `migrate` existe en el contrato con default `true`; ningún input previo cambia de tipo ni de default; ningún `name:` de job cambia | `test/gates/contract-sync.bats` (existente) |
| G-DB4 | Sin nombres internos en lo nuevo (contratos, docs, fixtures, mensajes) | `test/gates/public-names.bats` (existente, `INTERNAL_DENYLIST`) |
| G-DB5 | Cada id nuevo de la matriz de paridad existe, tiene estado y sus inputs existen en el contrato | `test/gates/parity.bats` (existente) |

---

## 5. Decisiones y alternativas descartadas

| # | Decisión | Descartado |
|---|---|---|
| D1 | `pip` solamente, con **pins obligatorios** (`==` o hashes) | Rangos permitidos; `uv`/`poetry` ahora (entran después como valor de un input) |
| D2 | Sin `venv`; instalación en el intérprete del runner | `venv` obligatorio: obliga a los comandos del caller a activarlo; el runner ya es efímero |
| D3 | `migrate` explícito, default `true` | Inferencia por inputs vacíos; `compute` nuevo |
| D4 | Los dos cambios salen juntos en una minor (`v1.3.0`) | Dos releases: duplica el trabajo de `release.yml` y de verificación para dos cambios chicos y ortogonales |
| D5 | `migrate` solo en `environment-deploy` | También en `cicd` (ya es opcional allí) |

---

## 6. Versionado y llegada a los callers

- **`v1.3.0` (minor):** tres inputs nuevos (`python-version`, `python-requirements` con default `""`; `migrate` con default `true`), un script, pasos
  condicionales en un composite y condiciones ampliadas. **No cambia** ningún `name:` de job (irreversible), ni inputs/outputs previos, ni el esquema de telemetría.
- **Llegada:** los callers en `@v1` reciben el cambio al moverse el alias; sin los inputs nuevos el comportamiento es idéntico a `v1.2.0`. Los callers
  fijados en `@v1.2.x` no cambian (los tags `vX.Y.Z` son inmutables).
- **Telemetría:** el colector valida `job_workflow_ref` contra `lego-*.yml@refs/tags/v…`; un tag nuevo sigue cumpliendo el patrón. Nada que coordinar con el colector.
- **Antes de liberar:** `git fetch --tags --prune`, `main` empujada con `self-ci` verde, `RELEASE_TOKEN` vigente y el secret `INTERNAL_DENYLIST` presente.
  El release lo crea **solo** `release.yml` (`workflow_dispatch`, `version=1.3.0`); nunca a mano.

---

## 7. Plan por fases

> Escrito para ejecución autónoma. **Una fase = un commit coherente**, en una rama `feat/<descripcion-en-español>`, sin push salvo la fase indicada.
> No se empieza la siguiente con la anterior en rojo. **Orden de cada fase: tests y gates primero, verificados en rojo (se ve fallar con el mensaje nombrando
> el archivo), luego la implementación, luego verde.** Si la realidad contradice este spec, **se detiene y se actualiza el spec primero**.
> No se toca ningún repo consumidor. Commits: `feat:`/`docs:`/`fix:`/`ref:` + inglés, imperativo, mayúscula inicial, sin punto final. Comandos para el humano en PowerShell;
> scripts del repo en bash. Suite local: `bats --recursive test/bats test/gates` (en Windows vía WSL, ver `AGENTS.md`). Cada fase corre la suite completa.

### F0 — Spec aprobado
- **Objetivo:** este documento aprobado por un mantenedor, con Q1 y Q2 resueltas.
- **Toca:** este archivo (estado → APROBADO, §9, §10). **No toca:** nada más.
- **Aceptación:** estado APROBADO y fecha en la cabecera.
- **Checkpoint:** `docs: Add the Python toolchain and optional database stage spec`.

### F1 — Toolchain de Python (A)
- **Objetivo:** un repo con `requirements` fijados migra, testea y lintea en el runner con Python de versión conocida.
- **Dependencias:** F0 (Q1 resuelta: pins obligatorios).
- **Toca:** `scripts/python-install.sh` (nuevo), `scripts/validate-inputs.sh`, `.github/actions/setup-project/action.yml`, los 7 pasos de `setup-project` en los dos workflows (inputs nuevos en
  `workflow_call` y paso a paso), `contracts/*.contract.yml`, `scripts/lib/versions.env` o equivalente si fija versiones, `test/bats/`, `test/gates/python-toolchain.bats`, `test/fixtures/python/**`.
  **No toca:** `lego-aws-environment-deploy` en su lógica de migración, composites de despliegue, telemetría, `release.yml`.
- **Tareas:** (1) fixtures de `requirements` válidos (pin, hashes, `-r` anidado) e inválidos (cada categoría de §3.1) y los bats G-PY1/G-PY2/G-PY3 y el gate G-PY4, **en rojo**; (2) `python-install.sh`;
  (3) validación en `validate-inputs.sh`; (4) `setup-project` + los 7 pasos; (5) contratos; (6) verde y verificación en rojo de G-PY4 quitando los inputs de un paso a propósito.
- **Aceptación (PowerShell, vía WSL):** `bats test/bats/validate-inputs-python.bats test/bats/python-install.bats test/gates/python-toolchain.bats test/gates/contract-sync.bats test/gates/pinned-actions.bats` → todo `ok`.
  **Rojo:** un `requirements` con `fastapi>=0.115` → el mensaje nombra archivo y línea; un `setup-project` sin los inputs → el gate nombra el workflow y el paso.
- **Rollback:** revertir el commit (inputs con default vacío: ningún caller depende de ellos todavía).
- **Checkpoint:** `feat: Add the Python toolchain to the setup-project composite`.

### F2 — Etapa de base de datos opcional (B)
- **Objetivo:** un servicio `ecs` sin base de datos despliega con `environment-deploy` y `migrate: false`.
- **Dependencias:** F0 (Q2 resuelta: `migrate`). F2 es independiente de F1 y puede ir en paralelo.
- **Toca:** `.github/workflows/lego-aws-environment-deploy.yml`, `scripts/validate-inputs.sh`, `contracts/lego-aws-environment-deploy.contract.yml`, `test/bats/validate-inputs-migrate.bats`,
  `test/gates/skip-database-stage.bats`, `test/gates/deploy-flow.bats` (fija la cadena exacta de la condición del paso de post-deploy, que cambia a `… || !inputs.migrate)`; descubierto al ejecutar F2, 2026-11-16),
  `test/bats/gates-red.bats` (casos en rojo de G-DB2/G-DB3), `test/bats/helpers.bash`, `test/sandbox/callers/` (un caller `ecs` sin base de datos). **No toca:** `lego-aws-cicd`, composites, scripts de migración y de túnel, telemetría.
- **Tareas:** (1) bats G-DB1 y gate G-DB2 en rojo; (2) input y condiciones de §3.2; (3) reglas de rechazo en `validate-inputs.sh`; (4) contrato; (5) caller sandbox y verificación de que el job de telemetría
  arma el payload con `database-migration` en `skipped` (escenario existente de `compute: static`); (6) verde y verificación en rojo de G-DB2 quitando `inputs.migrate` de una condición.
- **Aceptación:** `bats test/bats/validate-inputs-migrate.bats test/gates/skip-database-stage.bats test/gates/static-compute.bats test/gates/contract-sync.bats test/gates/rollback-and-event-guards.bats` → todo `ok`.
  **Rojo:** quitar `inputs.migrate` del `if:` del job `database-migration` → el gate nombra el workflow y el job.
- **Rollback:** revertir el commit (default `true`: ningún caller cambia).
- **Checkpoint:** `feat: Add the migrate input to skip the database stage in the environment deploy`.

### F3 — Paridad, documentación y sandbox
- **Objetivo:** nada de lo nuevo vive solo en la cabeza de quien lo escribió.
- **Dependencias:** F1 y F2.
- **Toca:** `docs/parity/matrix.yml` (ids nuevos: toolchain de Python en ambos flujos; etapa de BD omitible en `environment-deploy`), `docs/runbook.md`, `README.md` (tabla de inputs), `AGENTS.md` (§2: el consumidor
  Python y el servicio sin BD; corrige además la línea «Sin tag `v1`»/«`@v1` aún no existe», desactualizada desde `v1.0.0`), `test/sandbox/`, `test/gates/doc-coherence.bats` si cubre los textos tocados.
  **No toca:** workflows ni scripts.
- **Aceptación:** `bats --recursive test/bats test/gates` → todo `ok`; `git grep -n -i -E "sin tag|aún no existe"` sobre `AGENTS.md` y el runbook → vacío.
- **Rollback:** revertir el commit (solo documentación y matriz).
- **Checkpoint:** `docs: Document the Python toolchain and the optional database stage`.

### F4 — Release `v1.3.0` (acción de salida: requiere confirmación explícita)
- **Objetivo:** `v1.3.0` y alias `v1` publicados.
- **Dependencias:** F1–F3 en `main`, `self-ci` verde, checklist de §6. **Confirmación humana antes de ejecutar** (publica un tag que los consumidores resuelven por `@v1`).
- **Tareas:** empujar `main`; ejecutar `release.yml` con `version=1.3.0` (`gh workflow run release.yml -f version=1.3.0`); verificar `git ls-remote --tags origin v1 v1.3.0` y que `v1.2.0` no se movió.
- **Rollback:** los tags `vX.Y.Z` son inmutables: se corrige con `v1.3.1`; mover el alias `v1` de vuelta lo hace solo `release.yml`.
- **Checkpoint:** `docs: Record the v1.3.0 release` (§10).

### F5 — Aceptación real (con el primer consumidor)
- **Objetivo:** un run real en `dev` de cada modo nuevo, hecho por el consumidor, no desde este repo.
- **Dependencias:** F4. **Entrega al consumidor:** texto de hand-off en §10.
- **Aceptación:** un run verde con (A) `python-version` + `python-requirements` + `migration-command` de Python, y uno con (B) `migrate: false` sobre un servicio sin base de datos. Se registra el enlace de cada run en §10.
- **Rollback:** el consumidor vuelve a `@v1.2.0`.

---

## 8. Riesgos y puntos irreversibles

**Irreversibles (no se «corrigen después»):**

| # | Qué |
|---|---|
| I1 | Los **nombres** de los inputs `python-version`, `python-requirements` y `migrate` una vez publicados en `v1.3.0` (renombrar = versión mayor) |
| I2 | Los `name:` de los jobs (no cambian aquí; se anota para que nadie «aproveche» y los renombre) |

**Corregibles después:** mensajes de error, el límite de profundidad de `-r`, soporte de otros gestores, valores por defecto de versiones.

| # | Riesgo | Mitigación |
|---|---|---|
| R1 | Un pin con `==` **no** es un lockfile con hashes: el árbol transitivo puede variar si el archivo solo fija lo directo | La guía de F3 recomienda un archivo **compilado** (todas las dependencias, con hashes); G-PY3 acepta hashes y pip los exige solo |
| R2 | Los pins obligan al consumidor a congelar sus dependencias antes de adoptar (trabajo previo, no un fallo de la plantilla) | Documentado en F3; el error nombra archivo y línea |
| R3 | `setup-python` añade segundos por job que lo use; son 7 pasos | Solo corre con `python-version`; la caché de pip lo amortiza |
| R4 | `migrate: false` mal usado en un servicio que sí tiene base de datos: despliega código nuevo contra un esquema viejo | G-DB1 rechaza cualquier input `db-*` junto a `migrate: false`; el caller que migra no puede apagarlo sin borrar su configuración a la vista del review |
| R5 | La suite local corre en WSL; una divergencia entre WSL y `ubuntu-latest` | `self-ci` corre la misma suite en el runner antes del release (F4) |

---

## 9. Preguntas abiertas

| # | Pregunta | Estado |
|---|---|---|
| Q1 | ¿Pins obligatorios (`==` o hashes) o rangos con advertencia? | **Resuelta (2026-11-16): pins obligatorios** (recomendación del spec). Sin modo permisivo ni input para relajarlo. |
| Q2 | ¿`migrate` (boolean) o `database-stage: true|false`? | **Resuelta (2026-11-16): `migrate`**, por brevedad y paralelismo con `migrate-before-deploy`. Irreversible una vez publicado (I1). |
| Q3 | ¿El `-r` anidado se permite (propuesto, profundidad ≤ 3) o se exige un archivo plano? | Abierta, no bloquea: se ejecuta lo propuesto (se puede endurecer después). |

---

## 10. Estado de ejecución y prompt para retomar

| Fase | Estado |
|---|---|
| Spec | **APROBADO** (2026-11-16) |
| F0 | Hecha (2026-11-16) |
| F1 | Hecha (2026-11-16), rama `feat/toolchain-python-y-etapa-sin-bd`, sin push. Suite completa: 265 `ok`, 0 fallos (línea base previa: 249) |
| F2 | Hecha (2026-11-16), misma rama, sin push. Suite completa: 277 `ok`, 0 fallos; `shellcheck` y `actionlint` limpios |
| F3–F5 | Pendientes (F4 requiere confirmación humana explícita) |

**Notas de F2:**
- Las 5 condiciones están en `lego-aws-environment-deploy.yml`: paso del túnel, paso `migrate`, job `database-migration` y job `post-deploy` ganan `&& inputs.migrate`; el paso de post-deploy de `infra-deploy` gana `|| !inputs.migrate`. Ningún `name:` cambió.
- Trampa que el gate cubre: `inputs.migrate-before-deploy` contiene el prefijo `inputs.migrate`; los patrones de `test/gates/skip-database-stage.bats` lo excluyen y `gates-red.bats` tiene el caso trampa (una condición que solo trae `migrate-before-deploy` se reporta).
- `migrate: false` con `compute: static` no añade reglas (static ya rechaza lo suyo). La validación nueva solo corre para `compute != static`.
- Telemetría: sin cambios; el escenario existente de `test/bats/telemetry-payload.bats` (`needs_envdeploy success success skipped skipped`) es exactamente el resultado de un run con `migrate: false`.
- Caller sandbox: `test/sandbox/callers/environment-deploy-ecs-no-db.yml`. Su fila en `test/sandbox/README.md` entra en F3.

**Notas de F1 (para quien retome):**
- `python-install.sh` valida todos los archivos antes de instalar y reporta todos los problemas con `archivo:línea`. `-r`/`-c` anidados: relativos al archivo que los contiene, dentro del repo, profundidad ≤ 3, sin ciclos (Q3: se ejecutó lo propuesto).
- `setup-python` fijado en `v7.1.0` (SHA `6d4fd22b…`), igual que `setup-node`. La clave de caché de pip usa solo los archivos de nivel superior (los `-r` anidados no entran en la clave; pip sigue resolviendo bien, solo se pierde precisión de la caché).
- Gates nuevos, verificados en rojo contra el árbol real (quitando `python-requirements` de un paso) y con pruebas en `test/bats/gates-red.bats`: G-PY4 y G-PY5 en `test/gates/python-toolchain.bats`. G-PY5 vive ahí y no en `pinned-actions.bats` (que ya cubre el SHA por G3; el comentario de versión es lo único que añade).
- **Entorno local:** el test `tunnel-up/down` de `test/bats/ssm-tunnel.bats` es sensible al timing en el montaje `/mnt/c` de WSL (el `grep` del log corre antes de que el `aws` falso en segundo plano escriba) y falla ahí también en un `HEAD` limpio. Pasa en el filesystem nativo de WSL: copiar el árbol a `~` y correr la suite desde allí. No es un fallo de F1 ni se corrige aquí.

**Prompt para retomar (copiar tal cual):**

```text
Lee AGENTS.md, SPEC.md §0 y docs/specs/toolchain-python-y-etapa-sin-bd/SPEC.md de nextep-platform-workflows. Si el spec está APROBADO, ejecuta la primera fase pendiente de §7
respetando "Toca / No toca": tests y gates primero, en rojo y verificados en rojo; luego la implementación; una fase = un commit en una rama feat/ con el formato de §7.
El repo es PÚBLICO: nada de nombres de proyectos, cuentas ni dominios internos; relee el diff antes de cada commit.
```
