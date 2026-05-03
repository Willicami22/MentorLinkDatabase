#  MentorLink — Entregables del Arquitecto IA

> **Proyecto:** Sistema de Gestión de Mentorías "MentorLink"  
> **Rol:** Arquitecto IA  
> **Stack:** Supabase (PostgreSQL) + CLI + Auth  
> **Fecha:** Mayo 2026

---

## Tabla de Contenidos

1. [Prompt de IA Utilizado](#1-prompt-de-ia-utilizado)
2. [Scripts SQL Generados](#2-scripts-sql-generados)
   - [Tablas](#21-creación-de-tablas)
   - [Políticas RLS](#22-políticas-de-row-level-security-rls)
3. [Implementación con Supabase CLI](#3-implementación-con-supabase-cli)
4. [Guía de Configuración Auth](#4-guía-de-configuración-de-autenticación)

---

## 1. Prompt de IA Utilizado

El siguiente es el prompt exacto enviado al asistente de IA (Claude) para generar el esquema completo:

```
You are a senior database architect. Generate a complete SQL script for PostgreSQL
(Supabase compatible) for a mentorship platform.

Requirements:
- Create three tables: perfiles, sesiones, mensajes.
- perfiles: id (UUID, PK, references auth.users), nombre (text), bio (text),
  rol (mentor/estudiante).
- sesiones: id (UUID, PK), mentor_id (FK), estudiante_id (FK), fecha (timestamp),
  estado (pendiente/completada/cancelada).
- mensajes: id (UUID, PK), sesion_id (FK), remitente_id (FK), contenido (text),
  created_at (timestamp).

Constraints:
- Use proper foreign keys with ON DELETE CASCADE where appropriate.
- Add basic checks (e.g., rol values, estado values).

Security:
- Enable Row Level Security (RLS) on all tables.
- Users can:
  - Read/update their own perfil.
  - Read sesiones where they are mentor or estudiante.
  - Read mensajes only if they belong to a sesión they are part of.
  - Insert mensajes only if they are part of the sesión.

Output:
- Full SQL script including table creation and RLS policies.
```

**Herramienta utilizada:** Claude (Anthropic) — modelo claude-sonnet-4  
**Resultado:** Script SQL completo, listo para usar como migración de Supabase.

---

## 2. Scripts SQL Generados

### 2.1 Creación de Tablas

```sql
-- ============================================================
--  MENTORSHIP PLATFORM — PostgreSQL / Supabase Schema
--  Tablas: perfiles · sesiones · mensajes
-- ============================================================

-- EXTENSIONES
CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- habilita gen_random_uuid()

-- ============================================================
-- TABLA: perfiles
-- Una fila por usuario autenticado (espejo de auth.users)
-- ============================================================
CREATE TABLE IF NOT EXISTS public.perfiles (
    id         UUID        PRIMARY KEY
                           REFERENCES auth.users (id) ON DELETE CASCADE,
    nombre     TEXT        NOT NULL,
    bio        TEXT,
    rol        TEXT        NOT NULL
                           CHECK (rol IN ('mentor', 'estudiante')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON TABLE  public.perfiles     IS 'Perfil público de cada usuario autenticado.';
COMMENT ON COLUMN public.perfiles.rol IS 'mentor | estudiante';

-- Trigger: mantener updated_at al día
CREATE OR REPLACE FUNCTION public.set_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_perfiles_updated_at
BEFORE UPDATE ON public.perfiles
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- ============================================================
-- TABLA: sesiones
-- Sesión de mentoría entre un mentor y un estudiante
-- ============================================================
CREATE TABLE IF NOT EXISTS public.sesiones (
    id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    mentor_id     UUID        NOT NULL
                              REFERENCES public.perfiles (id) ON DELETE CASCADE,
    estudiante_id UUID        NOT NULL
                              REFERENCES public.perfiles (id) ON DELETE CASCADE,
    fecha         TIMESTAMPTZ NOT NULL,
    estado        TEXT        NOT NULL DEFAULT 'pendiente'
                              CHECK (estado IN ('pendiente', 'completada', 'cancelada')),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),

    -- Un usuario no puede ser mentor y estudiante en la misma sesión
    CONSTRAINT chk_sesiones_different_users
        CHECK (mentor_id <> estudiante_id)
);

COMMENT ON TABLE  public.sesiones        IS 'Sesiones de mentoría entre mentor y estudiante.';
COMMENT ON COLUMN public.sesiones.estado IS 'pendiente | completada | cancelada';

CREATE TRIGGER trg_sesiones_updated_at
BEFORE UPDATE ON public.sesiones
FOR EACH ROW EXECUTE FUNCTION public.set_updated_at();

-- Índices para consultas frecuentes
CREATE INDEX IF NOT EXISTS idx_sesiones_mentor_id     ON public.sesiones (mentor_id);
CREATE INDEX IF NOT EXISTS idx_sesiones_estudiante_id ON public.sesiones (estudiante_id);
CREATE INDEX IF NOT EXISTS idx_sesiones_estado        ON public.sesiones (estado);

-- ============================================================
-- TABLA: mensajes
-- Mensajes de chat dentro de una sesión
-- ============================================================
CREATE TABLE IF NOT EXISTS public.mensajes (
    id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sesion_id    UUID        NOT NULL
                             REFERENCES public.sesiones (id) ON DELETE CASCADE,
    remitente_id UUID        NOT NULL
                             REFERENCES public.perfiles  (id) ON DELETE CASCADE,
    contenido    TEXT        NOT NULL
                             CHECK (char_length(contenido) BETWEEN 1 AND 10000),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

COMMENT ON COLUMN public.mensajes.remitente_id
    IS 'Debe ser mentor_id o estudiante_id de la sesión.';

-- Trigger: solo los participantes de una sesión pueden enviar mensajes
CREATE OR REPLACE FUNCTION public.chk_remitente_is_participant()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.sesiones s
        WHERE  s.id = NEW.sesion_id
          AND (s.mentor_id = NEW.remitente_id
            OR s.estudiante_id = NEW.remitente_id)
    ) THEN
        RAISE EXCEPTION
            'remitente_id % no es participante de la sesion %',
            NEW.remitente_id, NEW.sesion_id;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_mensajes_check_participant
BEFORE INSERT ON public.mensajes
FOR EACH ROW EXECUTE FUNCTION public.chk_remitente_is_participant();

-- Índices
CREATE INDEX IF NOT EXISTS idx_mensajes_sesion_id    ON public.mensajes (sesion_id);
CREATE INDEX IF NOT EXISTS idx_mensajes_remitente_id ON public.mensajes (remitente_id);
CREATE INDEX IF NOT EXISTS idx_mensajes_created_at   ON public.mensajes (created_at);
```

---

### 2.2 Políticas de Row Level Security (RLS)

```sql
-- ============================================================
-- RLS — perfiles
-- ============================================================
ALTER TABLE public.perfiles ENABLE ROW LEVEL SECURITY;

-- El usuario puede leer su propio perfil
CREATE POLICY "perfiles: owner puede leer"
ON public.perfiles FOR SELECT
USING (auth.uid() = id);

-- El usuario puede actualizar su propio perfil
CREATE POLICY "perfiles: owner puede actualizar"
ON public.perfiles FOR UPDATE
USING      (auth.uid() = id)
WITH CHECK (auth.uid() = id);

-- El usuario puede insertar su propio perfil (al registrarse)
CREATE POLICY "perfiles: owner puede insertar"
ON public.perfiles FOR INSERT
WITH CHECK (auth.uid() = id);

-- Participantes de una sesión compartida pueden ver el perfil del otro
CREATE POLICY "perfiles: co-participante puede leer"
ON public.perfiles FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM public.sesiones s
        WHERE (s.mentor_id = auth.uid() OR s.estudiante_id = auth.uid())
          AND (s.mentor_id = perfiles.id OR s.estudiante_id = perfiles.id)
    )
);

-- ============================================================
-- RLS — sesiones
-- ============================================================
ALTER TABLE public.sesiones ENABLE ROW LEVEL SECURITY;

-- Un participante (mentor O estudiante) puede leer sus sesiones
CREATE POLICY "sesiones: participante puede leer"
ON public.sesiones FOR SELECT
USING (
    auth.uid() = mentor_id
    OR auth.uid() = estudiante_id
);

-- Solo un mentor puede crear una sesión (y debe ser el mentor_id)
CREATE POLICY "sesiones: mentor puede insertar"
ON public.sesiones FOR INSERT
WITH CHECK (
    auth.uid() = mentor_id
    AND EXISTS (
        SELECT 1 FROM public.perfiles p
        WHERE p.id = auth.uid() AND p.rol = 'mentor'
    )
);

-- Cualquier participante puede actualizar el estado (ej. cancelar)
CREATE POLICY "sesiones: participante puede actualizar"
ON public.sesiones FOR UPDATE
USING (
    auth.uid() = mentor_id OR auth.uid() = estudiante_id
)
WITH CHECK (
    auth.uid() = mentor_id OR auth.uid() = estudiante_id
);

-- ============================================================
-- RLS — mensajes
-- ============================================================
ALTER TABLE public.mensajes ENABLE ROW LEVEL SECURITY;

-- Un participante de la sesión puede leer sus mensajes
CREATE POLICY "mensajes: participante puede leer"
ON public.mensajes FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM public.sesiones s
        WHERE s.id = mensajes.sesion_id
          AND (s.mentor_id = auth.uid() OR s.estudiante_id = auth.uid())
    )
);

-- Un participante puede insertar mensajes en su sesión
CREATE POLICY "mensajes: participante puede insertar"
ON public.mensajes FOR INSERT
WITH CHECK (
    auth.uid() = remitente_id
    AND EXISTS (
        SELECT 1 FROM public.sesiones s
        WHERE s.id = sesion_id
          AND (s.mentor_id = auth.uid() OR s.estudiante_id = auth.uid())
    )
);
```

---

## 3. Implementación con Supabase CLI

### 3.1 Prerequisitos

```bash
# Instalar Supabase CLI (macOS/Linux)
brew install supabase/tap/supabase

# Verificar instalación
supabase --version
# Output esperado: supabase version 1.x.x

# Iniciar sesión con tu cuenta de Supabase
supabase login
# Abrirá el navegador para autenticación OAuth
```

### 3.2 Inicializar y vincular el proyecto

```bash
# 1. Inicializar el proyecto local (crea carpeta supabase/)
supabase init

# Estructura generada:
# supabase/
# ├── config.toml       ← configuración del proyecto
# └── migrations/       ← aquí vivirán los archivos SQL

# 2. Vincular con tu proyecto remoto de Supabase
#    (obtén el PROJECT_ID desde app.supabase.com → Settings → General)
supabase link --project-ref <PROJECT_ID>
```

### 3.3 Crear y aplicar la migración

```bash
# 3. Generar el archivo de migración
supabase migration new inicializar_esquema

# Output:
# Created new migration at supabase/migrations/20250501000000_inicializar_esquema.sql

# 4. Pegar el script SQL completo en el archivo generado
#    supabase/migrations/20250501000000_inicializar_esquema.sql

# 5. Aplicar la migración a la base de datos remota
supabase db push

# Output esperado:
# Applying migration 20250501000000_inicializar_esquema.sql...
# Migration applied successfully!
```

### 3.4 Verificación

```bash
# Verificar el estado de las migraciones aplicadas
supabase migration list

# Output esperado:
# ┌─────────────────────────────────────────────────────────────┐
# │ LOCAL                         │ REMOTE    │ TIME (UTC)       │
# ├─────────────────────────────────────────────────────────────┤
# │ 20250501000000_inicializar... │ ✔ applied │ 2025-05-01 ...   │
# └─────────────────────────────────────────────────────────────┘

# (Opcional) Abrir Supabase Studio local para inspeccionar las tablas
supabase start
supabase studio
```

### 3.5 Log de comandos ejecutados (resumen)

| # | Comando | Propósito |
|---|---------|-----------|
| 1 | `supabase login` | Autenticarse con Supabase Cloud |
| 2 | `supabase init` | Crear estructura local del proyecto |
| 3 | `supabase link --project-ref <ID>` | Vincular repo local con proyecto remoto |
| 4 | `supabase migration new inicializar_esquema` | Crear archivo de migración vacío |
| 5 | *(editar el .sql generado)* | Pegar el script completo del esquema |
| 6 | `supabase db push` | Aplicar migración a Supabase Cloud |
| 7 | `supabase migration list` | Confirmar que la migración fue aplicada |

### 3.6 Imagen de Supabase CLI

![Uso de SupaBaseCLI](/imgs/SupabaseCLI.png)
---

## 4. Guía de Configuración de Autenticación

### Proveedores habilitados

| Proveedor | Tipo | Estado recomendado |
|-----------|------|--------------------|
| Email/Password | Nativo |  Habilitado |
| Google OAuth 2.0 | Externo |  Habilitado |

---

### Paso 1 — Habilitar Email/Password en el Dashboard

1. Ingresa a [app.supabase.com](https://app.supabase.com) y selecciona tu proyecto **MentorLink**.
2. En el menú lateral, ve a **Authentication → Providers**.
3. Localiza el proveedor **Email** (ya viene habilitado por defecto).
4. Verifica que esté activo y configura según necesidad:
   -  **Enable Email provider** → ON
   -  **Confirm email** → ON *(recomendado para producción)*
   -  **Secure email change** → ON *(opcional pero recomendado)*
5. Haz clic en **Save**.

---

### Paso 2 — Crear credenciales OAuth en Google Cloud Console

> Antes de configurar Supabase, necesitas un **Client ID** y **Client Secret** de Google.

1. Ve a [console.cloud.google.com](https://console.cloud.google.com) y crea un proyecto (o usa uno existente).
2. Navega a **APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID**.
3. Selecciona **Application type: Web application** y asígnale el nombre `MentorLink`.
4. En **Authorized redirect URIs**, agrega la URL de callback de Supabase:
   ```
   https://<TU_PROJECT_ID>.supabase.co/auth/v1/callback
   ```
   > Reemplaza `<TU_PROJECT_ID>` con el ID de tu proyecto (visible en Supabase → Settings → General).
5. Haz clic en **Create** y copia el **Client ID** y **Client Secret** generados.

---

### Paso 3 — Configurar el proveedor de Google en Supabase

1. Vuelve a **app.supabase.com → Authentication → Providers**.
2. Localiza el proveedor **Google** y haz clic para expandirlo.
3. Activa el toggle **Enable Google provider → ON**.
4. Pega las credenciales obtenidas en el paso anterior:
   - **Client ID (for OAuth):** `<TU_GOOGLE_CLIENT_ID>`
   - **Client Secret:** `<TU_GOOGLE_CLIENT_SECRET>`
5. Copia la **Callback URL** que muestra Supabase y verifica que coincida con la que registraste en Google Cloud.
6. Haz clic en **Save**.

```
 Resultado: Los usuarios de MentorLink podrán registrarse e iniciar sesión
   con su cuenta de Google o con Email/Password.
```

---

### Referencia rápida: Flujo de autenticación

```
[Usuario]
    │
    ├─── Email/Password ──→ [Supabase Auth] ──→ JWT Token
    │
    └─── "Continuar con Google" ──→ [Google OAuth] ──→ [Supabase Auth] ──→ JWT Token
                                                              │
                                                              ▼
                                                   Trigger: crea fila en
                                                   public.perfiles (on signup)
```


