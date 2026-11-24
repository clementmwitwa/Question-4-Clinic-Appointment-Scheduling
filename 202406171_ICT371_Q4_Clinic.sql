-- ICT371 Advanced Database | Question 4: Clinic Appointment Scheduling
-- Student: Clement Mwitwa | Student No: 202406171 | PostgreSQL
-- Slots per doctor per day: 09:00, 10:00, 11:00, 12:00.

DROP SCHEMA IF EXISTS q4_clinic CASCADE;
CREATE SCHEMA q4_clinic;
SET search_path = q4_clinic, public;

/* ===================== (a) Database and seed data ===================== */
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER     NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER     NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT ck_slot   CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
    CONSTRAINT ck_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

-- Safety net for concurrent sessions: the database itself refuses two non-cancelled
-- appointments in the same doctor/date/slot (the trigger below gives the friendly message).
CREATE UNIQUE INDEX uq_active_slot ON appointments (doctor_id, appointment_day, slot_time)
WHERE status <> 'CANCELLED';

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL,
    attended_count  INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

INSERT INTO patients (full_name) VALUES ('Grace Mumba'), ('Joseph Kunda'), ('Ruth Chola');
INSERT INTO doctors  (full_name) VALUES ('Dr. Mutale'), ('Dr. Siame'), ('Dr. Njovu');

-- Six appointments, no slot clashes. A cancelled slot may be reused (see Dr. Mutale 09:00 yesterday).
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE - 1, '09:00', 'CANCELLED'),
    (2, 1, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
    (3, 2, CURRENT_DATE - 1, '10:00', 'ATTENDED'),
    (1, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
    (2, 2, CURRENT_DATE,     '11:00', 'BOOKED'),
    (3, 3, CURRENT_DATE + 1, '12:00', 'BOOKED');

/* ===================== (b) Function ===================== */
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql AS $$
DECLARE
    v_count INTEGER;
BEGIN
    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count          -- COUNT(*) is 0 when the day has no bookings
    FROM appointments
    WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED';
    RETURN v_count;
END;
$$;

/* ===================== (c) Procedure ===================== */
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INTEGER, p_doctor_id INTEGER, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;

    PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past or NULL', p_day;
    END IF;

    IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;

    -- Slot clashes are rejected by the BEFORE trigger on appointments.
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

/* ===================== (d) Trigger ===================== */
CREATE OR REPLACE FUNCTION trg_fn_check_clash()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' AND EXISTS (
        SELECT 1 FROM appointments a
        WHERE a.doctor_id       = NEW.doctor_id
          AND a.appointment_day = NEW.appointment_day
          AND a.slot_time       = NEW.slot_time
          AND a.status         <> 'CANCELLED'
          -- On UPDATE the row being changed must not clash with itself.
          AND a.appointment_id IS DISTINCT FROM NEW.appointment_id
    ) THEN
        RAISE EXCEPTION 'Clash: doctor % already has an appointment on % at %',
                        NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_clash();

-- Tests
SELECT fn_daily_load(1, CURRENT_DATE) AS load_today_dr1,
       fn_daily_load(1, CURRENT_DATE - 1) AS load_yesterday_dr1_cancelled_excluded,
       fn_daily_load(3, CURRENT_DATE + 30) AS load_empty_day;
DO $$ BEGIN PERFORM fn_daily_load(99, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

CALL pr_book_appointment(1, 3, CURRENT_DATE + 2, '09:00');   -- valid
DO $$ BEGIN CALL pr_book_appointment(2, 3, CURRENT_DATE + 2, '09:00');   -- clash
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 3, CURRENT_DATE - 1, '09:00');   -- past
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 3, CURRENT_DATE + 2, '13:00');   -- bad slot
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(99, 3, CURRENT_DATE + 2, '10:00');  -- bad patient
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

-- UPDATE behaviour: re-saving a row onto its own slot is fine; moving onto a taken slot is rejected.
UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 4;    -- OK (excludes itself)
DO $$ BEGIN UPDATE appointments SET doctor_id = 2, slot_time = '11:00' WHERE appointment_id = 4;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

/* ===================== (e) View ===================== */
-- Only the patient's name, doctor's name and slot are exposed (no IDs, no other patient data).
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;

/* ===================== (f) Index ===================== */
-- Justification: the clinic looks up "this doctor's appointments on this day". A non-unique
-- composite index (appointment_day, doctor_id) matches both equality conditions, and it also
-- speeds up the per-day summary and the clash/load checks that filter on the same columns.
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;

/* ===================== (g) Scheduled job ===================== */
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE          -- rerun replaces that date's summary
        SET booked_count = EXCLUDED.booked_count,
            attended_count = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- Every day at 01:00 (pg_cron time zone), summarise the previous day.
SELECT cron.schedule('q4_refresh_clinic_summary_daily', '0 1 * * *',
                     $$CALL q4_clinic.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);   -- rerun: still one row
SELECT * FROM clinic_summary;                       -- expected: booked 0, attended 2, cancelled 1
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q4_refresh_clinic_summary_daily';
