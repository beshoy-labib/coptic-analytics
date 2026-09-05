/* 
 Initializes the database.
 Drops the 14 tables and the three trigger functions if they already exist,
 then recreates every table with its keys, checks and composite-FK tenant
 isolation. Re-runnable from scratch; destructive to any existing data.
 Requires PostgreSQL 15+.
*/

BEGIN;

-- Clean slate. CASCADE clears the foreign keys between the tables; triggers
-- drop with their table, but the functions they call do not, so they go too.
DROP TABLE IF EXISTS
    app_user,
    selection,
    attendance,
    event,
    selection_slot,
    activity,
    member_class,
    member,
    family,
    class,
    department,
    church,
    diocese,
    app_role
CASCADE;

DROP FUNCTION IF EXISTS set_updated_at();
DROP FUNCTION IF EXISTS forbid_delete();
DROP FUNCTION IF EXISTS validate_timezone();


-- Provides gist_uuid_ops for member_class's exclusion constraint; core gist
-- lacks it. Out of `public` for Supabase's linter — the search_path is what
-- keeps the constraint resolvable on plain PostgreSQL.
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA extensions;
SET LOCAL search_path = public, extensions;


-- Reference data -------------------------------------------------------------

-- Natural key: app_user_scope_valid needs the role readable as a local column
-- and a CHECK cannot reference another table. Named app_role because PostgreSQL
-- and Supabase RLS both already use "role".
CREATE TABLE app_role (
    role_name   text PRIMARY KEY,
    scope_level text NOT NULL
        CHECK (scope_level IN ('platform', 'diocese', 'church', 'department', 'class'))
);


-- Church hierarchy -----------------------------------------------------------

CREATE TABLE diocese (
    diocese_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name       text NOT NULL,
    country    text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

CREATE TABLE church (
    church_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    diocese_id  uuid NOT NULL REFERENCES diocese (diocese_id),
    church_name text NOT NULL,
    city        text,
    country     text,

    -- Priest settings. timezone is an IANA name: a diocese can span countries,
    -- so "this week" is only defined relative to the church. Validated against
    -- pg_timezone_names by a trigger in 003 — a CHECK cannot query a view.
    absence_threshold_weeks int  NOT NULL DEFAULT 4
        CHECK (absence_threshold_weeks > 0),
    timezone                text NOT NULL DEFAULT 'UTC',

    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz
);

CREATE TABLE department (
    department_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    church_id       uuid NOT NULL REFERENCES church (church_id),
    department_name text NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,
    UNIQUE (department_id, church_id)
);

CREATE TABLE class (
    class_id      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    church_id     uuid NOT NULL REFERENCES church (church_id),
    department_id uuid NOT NULL,
    class_name    text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,
    UNIQUE (class_id, church_id),
    FOREIGN KEY (department_id, church_id)
        REFERENCES department (department_id, church_id)
);


-- People ---------------------------------------------------------------------

CREATE TABLE family (
    family_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    church_id   uuid NOT NULL REFERENCES church (church_id),
    family_name text NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz,
    UNIQUE (family_id, church_id)
);

-- The head of family is member.is_head_of_family, not a column here:
-- family.head_member_id would close a cycle against member.family_id.
CREATE TABLE member (
    member_id     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    church_id     uuid NOT NULL REFERENCES church (church_id),
    family_id     uuid,
    member_name   text NOT NULL,

    date_of_birth date,
    gender        text CHECK (gender IN ('male', 'female')),

    -- Held to one per family by uq_family_head in 002.
    is_head_of_family boolean NOT NULL DEFAULT false,

    -- Membership lifecycle, distinct from row lifecycle: these describe the
    -- person, deleted_at describes a data-entry error. created_at cannot serve
    -- as joined_date — a bulk import would stamp the whole congregation today.
    joined_date   date NOT NULL DEFAULT CURRENT_DATE,
    left_date     date,

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,

    UNIQUE (member_id, church_id),

    FOREIGN KEY (family_id, church_id)
        REFERENCES family (family_id, church_id),

    CONSTRAINT member_left_after_joined
        CHECK (left_date IS NULL OR left_date >= joined_date),

    CONSTRAINT member_head_needs_family
        CHECK (NOT is_head_of_family OR family_id IS NOT NULL)
);

-- Enrollment with history. The roster as at date D is the rows where
-- valid_from <= D < coalesce(valid_to, 'infinity'). Members are promoted a
-- class each year, so current state alone cannot answer a historical rate.
CREATE TABLE member_class (
    member_class_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    church_id       uuid NOT NULL REFERENCES church (church_id),
    class_id        uuid NOT NULL,
    member_id       uuid NOT NULL,
    valid_from      date NOT NULL DEFAULT CURRENT_DATE,
    valid_to        date,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    deleted_at      timestamptz,

    FOREIGN KEY (class_id, church_id)  REFERENCES class  (class_id, church_id),
    FOREIGN KEY (member_id, church_id) REFERENCES member (member_id, church_id),

    CONSTRAINT member_class_valid_range
        CHECK (valid_to IS NULL OR valid_to > valid_from),

    -- Overlapping enrollments would count one member twice in the roster.
    -- daterange is half-open: valid_to is the first day NOT in the class.
    CONSTRAINT member_class_no_overlap
        EXCLUDE USING gist (
            class_id  WITH =,
            member_id WITH =,
            daterange(valid_from, valid_to) WITH &&
        ) WHERE (deleted_at IS NULL)
);


-- Activities and attendance --------------------------------------------------

CREATE TABLE activity (
    activity_id   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    church_id     uuid NOT NULL REFERENCES church (church_id),
    activity_name text NOT NULL,

    -- Leaderboard inputs. They sit here rather than in a settings table because
    -- activity is already church-scoped. weight is bounded because unbounded
    -- numeric arrives in Spark as DecimalType(38,18).
    is_mandatory  boolean NOT NULL DEFAULT false,
    weight        numeric(5,2) NOT NULL DEFAULT 1 CHECK (weight >= 0),

    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,
    UNIQUE (activity_id, church_id)
);

-- Controlled vocabulary for the fairness tracker: 'Pauline', 'Psalm', 'Gospel'.
-- A table rather than free text because the calculation groups by slot.
CREATE TABLE selection_slot (
    slot_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    church_id  uuid NOT NULL REFERENCES church (church_id),
    slot_name  text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz,
    UNIQUE (slot_id, church_id)
);

-- One occurrence of an activity on a date. class_id NULL is a church-wide
-- occurrence; set is a single class's session. Without that distinction a class
-- that did not meet is indistinguishable from one where nobody came.
CREATE TABLE event (
    event_id    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    church_id   uuid NOT NULL REFERENCES church (church_id),
    activity_id uuid NOT NULL,
    class_id    uuid,
    recorded_by uuid,
    event_date  date NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    deleted_at  timestamptz,
    UNIQUE (event_id, church_id),

    -- One occurrence per activity per class per day: uq_event_grain in 002.

    FOREIGN KEY (activity_id, church_id)
        REFERENCES activity (activity_id, church_id),
    FOREIGN KEY (class_id, church_id)
        REFERENCES class (class_id, church_id),
    FOREIGN KEY (recorded_by, church_id)
        REFERENCES member (member_id, church_id)
);

-- Evidence against the roster, not the population itself: no row means absent,
-- 'absent' means a servant looked and marked them. The status is binary so the
-- rate is unambiguous: present / expected. The denominator is the roster as at
-- the event date.
CREATE TABLE attendance (
    attendance_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    church_id     uuid NOT NULL REFERENCES church (church_id),
    event_id      uuid NOT NULL,
    member_id     uuid NOT NULL,

    -- The class the member sat in on the day. A snapshot, deliberately not
    -- validated against member_class: members move up each year, and forcing
    -- agreement with today's roster would make last year's attendance
    -- unanswerable. Derivable from the validity dates, kept so the gold layer
    -- never has to range-join for it.
    class_id      uuid,

    status        text NOT NULL
        CHECK (status IN ('present', 'absent')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,

    -- One row per member per event: uq_attendance_event_member in 002.
    FOREIGN KEY (event_id, church_id)  REFERENCES event  (event_id, church_id),
    FOREIGN KEY (member_id, church_id) REFERENCES member (member_id, church_id),
    FOREIGN KEY (class_id, church_id)  REFERENCES class  (class_id, church_id)
);

-- Who was picked for which slot at which event. Separate from attendance
-- because being chosen is not the same as turning up, and "whose turn is it"
-- has to count assignments rather than appearances.
CREATE TABLE selection (
    selection_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    church_id    uuid NOT NULL REFERENCES church (church_id),
    event_id     uuid NOT NULL,
    member_id    uuid NOT NULL,
    slot_id      uuid NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    deleted_at   timestamptz,

    -- One member per slot per event: uq_selection_event_slot in 002.
    FOREIGN KEY (event_id, church_id)  REFERENCES event          (event_id, church_id),
    FOREIGN KEY (member_id, church_id) REFERENCES member         (member_id, church_id),
    FOREIGN KEY (slot_id, church_id)   REFERENCES selection_slot (slot_id, church_id)
);


-- Access control -------------------------------------------------------------

-- One row per login across all three authority tiers. The scope columns are
-- nullable because which one applies depends on the role; app_user_scope_valid
-- enforces that exactly the right subset is set.
--
-- member_id links church staff to their member record and stays NULL for
-- bishops and the platform admin. This is the only place a servant exists —
-- an active servant is a live row here whose member has not left.
--
-- user_id has no FK to auth.users so the schema stays testable on plain
-- PostgreSQL. Worth adding once the auth flow is built.
CREATE TABLE app_user (
    user_id       uuid PRIMARY KEY,               -- = auth.users.id
    role_name     text NOT NULL REFERENCES app_role (role_name),
    diocese_id    uuid REFERENCES diocese (diocese_id),
    church_id     uuid REFERENCES church (church_id),
    department_id uuid,
    class_id      uuid,
    member_id     uuid UNIQUE,
    email         text NOT NULL UNIQUE,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    deleted_at    timestamptz,

    FOREIGN KEY (department_id, church_id)
        REFERENCES department (department_id, church_id),
    FOREIGN KEY (class_id, church_id)
        REFERENCES class (class_id, church_id),
    FOREIGN KEY (member_id, church_id)
        REFERENCES member (member_id, church_id),

    -- member_id is constrained here rather than by the composite FK: that FK is
    -- MATCH SIMPLE, so it is skipped entirely when church_id is NULL, which is
    -- exactly the case for the two tiers that sit above a church.
    CONSTRAINT app_user_scope_valid CHECK (
           (role_name = 'platform_admin'
            AND diocese_id IS NULL AND church_id IS NULL
            AND department_id IS NULL AND class_id IS NULL
            AND member_id IS NULL)
        OR (role_name = 'bishop'
            AND diocese_id IS NOT NULL AND church_id IS NULL
            AND department_id IS NULL AND class_id IS NULL
            AND member_id IS NULL)
        OR (role_name IN ('priest', 'chief_manager')
            AND church_id IS NOT NULL
            AND department_id IS NULL AND class_id IS NULL)
        OR (role_name = 'department_manager'
            AND church_id IS NOT NULL AND department_id IS NOT NULL
            AND class_id IS NULL)
        OR (role_name = 'servant'
            AND church_id IS NOT NULL AND class_id IS NOT NULL
            AND department_id IS NULL)
    )
);

COMMIT;
