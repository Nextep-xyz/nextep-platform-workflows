# nextep-platform-workflows

> El motor de CI/CD de Nextep: **workflows reutilizables de GitHub Actions**, versionados e inmutables.
> Ningún proyecto define su propio pipeline; todos **llaman** a estos.
> Qué se construye y en qué orden: [`SPEC.md`](./SPEC.md). Reglas para agentes: [`AGENTS.md`](./AGENTS.md).

**Estado:** P1 (`lego-aws-cicd` y `lego-aws-environment-deploy`) implementada y verificada **solo en local**
(bats, actionlint, shellcheck, gitleaks). **No verificado contra una cuenta AWS real**: spikes S1/S3/S4 e integración
en `dev` pendientes (`docs/adr/`, `test/sandbox/README.md`). No existe ningún tag `v1`; todavía no hay nada que consumir.
La enmienda vigente sobre el resto del diseño está en `SPEC.md §0`; la guía de adopción en `docs/runbook.md`.

**Este repo es público.** No contiene secretos, cuentas cloud, URLs internas ni referencias a proyectos
concretos: todo lo específico entra por parámetros (`inputs`, `secrets`, `vars`) de quien llama. La seguridad
descansa en OIDC y en la identidad del workflow, no en ocultar la lógica.

---

## 1. Idea: Zero Copy-Paste CI/CD

Cuando cada repo copia su pipeline, el mismo "desplegar un ambiente" existe N veces con N bugs distintos: ARN
literales en el YAML, túneles con la verificación de TLS apagada, pipelines sin `concurrency` o sin rollback.
Cada copia envejece sola.

La regla: **el pipeline se escribe una vez, aquí, y los proyectos lo invocan por versión** (`@v1`). Un proyecto
solo declara *qué* es (ambiente, servicio, rol) y **no** *cómo* se construye, se prueba y se despliega.

- Corregir un bug del pipeline = un release aquí, no 30 PRs.
- Un proyecto nuevo tiene CI/CD correcto el día 1, sin que nadie lo diseñe.
- La seguridad no depende de que cada equipo recuerde la regla: está dentro del workflow.

---

## 2. Cómo funciona (en una pantalla)

```mermaid
flowchart LR
    subgraph ORG["Organización que consume los workflows"]
        R["Repo del proyecto<br/>caller de pocas líneas"]
        RUN["Runner<br/>(cómputo y minutos de ESTA org)"]
    end
    subgraph PLAT["nextep-platform-workflows"]
        W["Workflows reutilizables<br/>@v1 (inmutable)"]
    end
    R -->|"uses: ...@v1"| W
    W -->|"la lógica se ejecuta en"| RUN
    RUN -->|"OIDC (sin llaves)"| CLOUD["AWS / Azure<br/>cuenta del proyecto"]
    RUN -->|"métricas DORA"| COL["Colector configurable<br/>(opcional)"]
```

- **La lógica vive aquí; el cómputo corre en la organización de quien llama.** Los secretos y la cuenta cloud
  nunca salen de esa organización.
- **Sin credenciales estáticas.** El runner se autentica contra AWS/Azure por OIDC. El rol en la nube solo
  acepta tokens emitidos por **este** workflow (condición `job_workflow_ref`): un pipeline "propio" en el
  repo consumidor, aunque pida el mismo rol, es rechazado.
- **Gobernanza en el repo del proyecto:** `CODEOWNERS` protege `.github/workflows/`, y el proyecto cumple el
  contrato del `Makefile` universal (`make lint`, `make test-ci`, …) que los workflows ejecutan.

---

## 3. Catálogo

| Workflow | Estado | Para qué |
|---|---|---|
| `lego-aws-cicd` | Implementado (P1) | Flujo rápido: gate → migración (si hay pendientes, túnel SSM) → deploy. `compute: lambda \| ecs` |
| `lego-aws-environment-deploy` | Implementado (P1) | Ambiente completo: gate → infra (sin el stack del rol OIDC) → migraciones → verificación → seed; rollback por `image-tag` |
| `lego-azure-satellite` | Diseño | Satélites Core–Satélite en Azure. Fuera de P1 |

Los dos de AWS son por **flujo**, no por cómputo (`SPEC.md §0`). Secuencia del rápido:
**`quality-and-security-gate` → `database-migration` → `deploy`**. El job `telemetry-phone-home` está escrito pero
**comentado** hasta que exista el colector (sección 4).

Además cada ejecución **le cuenta lo que pasó** a quien la lee: un resumen en la pestaña del run y un comentario
en el PR cuando falla un gate o termina un deploy, con enlace directo al log.

---

## 4. Telemetría DORA ("phone home"), sin sorpresas

> **Hoy no se envía nada:** el bloque está comentado en ambos workflows (un gate falla si se descomenta).

El último job de cada workflow envía **una métrica de despliegue** a un colector **que tú configuras**
(`telemetry-url`; si lo dejas vacío, no se envía nada), siempre (`if: always()`), incluso si el deploy falló. Sirve para medir frecuencia de despliegue, lead time, tasa de
fallos y tiempo de recuperación.

- **Qué se envía:** repositorio, ambiente, resultado, duración por etapa, commit y tiempos. El payload exacto
  está en `SPEC.md` y **se imprime en el resumen de cada run**: puedes ver lo que salió.
- **Qué no se envía:** código, diffs, secretos, variables de entorno, logs.
- **Nunca rompe un deploy:** si el colector no responde, el pipeline sigue en verde.

---

## 5. Estructura

```
nextep-platform-workflows/
├── README.md   ← la idea (este archivo)
├── SPEC.md     ← contratos, secuencia de jobs, plan por fases
├── AGENTS.md   ← reglas para agentes (CLAUDE.md lo importa)
├── .github/workflows/  lego-aws-cicd, lego-aws-environment-deploy, self-ci
├── .github/actions/    composites internos (aws-oidc, ssm-tunnel, migrate, infra-deploy, ...)
├── scripts/            lógica en bash, con tests
├── contracts/          contratos máquina-legibles de cada workflow
├── test/               bats, gates por disco, fixtures, sandbox/callers
└── docs/               adr/ (spikes), iam/, parity/ (matriz), exceptions.yml, runbook.md
```
