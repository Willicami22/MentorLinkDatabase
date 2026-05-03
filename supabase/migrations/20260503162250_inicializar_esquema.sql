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