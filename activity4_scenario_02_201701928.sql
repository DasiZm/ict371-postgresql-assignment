/*
ICT371 PostgreSQL Scenario Assignment
Student Number: 201701928
Scenario: 2 - Computer Laboratory Reservations
*/
/*_______________Step 1:Tables and sample data  ____________________________*/
DROP TABLE IF EXISTS reservations;
DROP TABLE IF EXISTS lab_sessions;

CREATE TABLE lab_sessions (
    session_id             serial PRIMARY KEY,
    session_name           text NOT NULL UNIQUE,
    total_workstations     int  NOT NULL CHECK (total_workstations > 0),
    available_workstations int  NOT NULL,
    CHECK (available_workstations BETWEEN 0 AND total_workstations)
);

CREATE TABLE reservations (
    reservation_id   serial PRIMARY KEY,
    session_id       int  NOT NULL REFERENCES lab_sessions(session_id),
    lecturer         text NOT NULL CHECK (length(btrim(lecturer)) > 0),
    workstations     int  NOT NULL CHECK (workstations > 0),
    status           text NOT NULL DEFAULT 'ACTIVE'
                     CHECK (status IN ('ACTIVE', 'CANCELLED')),
    reserved_at      timestamptz NOT NULL DEFAULT now(),
    cancelled_at     timestamptz
);

INSERT INTO lab_sessions (session_name, total_workstations, available_workstations) VALUES
    ('Mon 08:00 Networking', 30, 30),
    ('Tue 10:00 Databases',  30,  4),
    ('Wed 14:00 Python',     25,  0),
    ('Thu 09:00 Security',   20, 20);


/*_______________Step 2:IF / ELSIF / ELSE session report  ____________________________*/
DO $$
DECLARE
    rec record;
    v_nearly_full CONSTANT int := 5;
BEGIN
    FOR rec IN SELECT session_name, available_workstations
               FROM lab_sessions ORDER BY session_id LOOP
        IF rec.available_workstations = 0 THEN
            RAISE NOTICE '%: FULL', rec.session_name;
        ELSIF rec.available_workstations <= v_nearly_full THEN
            RAISE NOTICE '%: NEARLY FULL (% left)', rec.session_name, rec.available_workstations;
        ELSE
            RAISE NOTICE '%: enough workstations (%)', rec.session_name, rec.available_workstations;
        END IF;
    END LOOP;
END $$;

/*_______________Step 3:WHILE and numeric FOR  ____________________________*/
DO $$
DECLARE
    v_reminder int := 1;
BEGIN
    WHILE v_reminder <= 3 LOOP
        RAISE NOTICE 'Session preparation reminder %', v_reminder;
        v_reminder := v_reminder + 1;
    END LOOP;

    FOR i IN 1..3 LOOP
        RAISE NOTICE 'Workstation check #%', i;
    END LOOP;
END $$;

/*_______________Step 4:reserve_workstations procedure  ____________________________*/
CREATE OR REPLACE PROCEDURE reserve_workstations(
    p_session_id int,
    p_lecturer   text,
    p_count      int
)
LANGUAGE plpgsql AS $$
DECLARE
    v_available int;
BEGIN
    IF p_count IS NULL OR p_count <= 0 THEN
        RAISE EXCEPTION 'Invalid workstation quantity: % (must be at least 1)', p_count
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_lecturer IS NULL OR btrim(p_lecturer) = '' THEN
        RAISE EXCEPTION 'Lecturer name is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Lock the session so concurrent reservations cannot oversell capacity
    SELECT available_workstations INTO v_available
    FROM lab_sessions
    WHERE session_id = p_session_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Session % not found', p_session_id;
    END IF;

    IF v_available < p_count THEN
        RAISE EXCEPTION 'Insufficient capacity: requested %, available %', p_count, v_available;
    END IF;

    UPDATE lab_sessions
    SET available_workstations = available_workstations - p_count
    WHERE session_id = p_session_id;

    INSERT INTO reservations (session_id, lecturer, workstations)
    VALUES (p_session_id, btrim(p_lecturer), p_count);

    RAISE NOTICE 'Reserved % workstation(s) in session % for %',
                 p_count, p_session_id, btrim(p_lecturer);
END $$;

/*_______________Step 5:Two valid calls, one exceeding capacity  ____________________________*/
CALL reserve_workstations(1, 'Dr. Mwansa', 20);   -- Networking: 30 -> 10
CALL reserve_workstations(2, 'Ms. Banda', 3);     -- Databases: 4 -> 1

DO $$
BEGIN
    CALL reserve_workstations(2, 'Mr. Phiri', 10);   -- only 1 left
EXCEPTION
    WHEN raise_exception THEN
        RAISE NOTICE 'Rejected: %', SQLERRM;
END $$;

SELECT * FROM lab_sessions ORDER BY session_id;
SELECT * FROM reservations ORDER BY reservation_id;

/*_______________Step 6:cancel_reservation procedure  ____________________________*/
CREATE OR REPLACE PROCEDURE cancel_reservation(p_reservation_id int)
LANGUAGE plpgsql AS $$
DECLARE
    v_session_id int;
    v_count      int;
    v_status     text;
BEGIN
    SELECT session_id INTO v_session_id
    FROM reservations WHERE reservation_id = p_reservation_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Reservation % not found', p_reservation_id;
    END IF;

    -- Lock session first, then reservation: same order as reserve_workstations
    PERFORM 1 FROM lab_sessions WHERE session_id = v_session_id FOR UPDATE;

    SELECT workstations, status INTO v_count, v_status
    FROM reservations
    WHERE reservation_id = p_reservation_id
    FOR UPDATE;

    IF v_status = 'CANCELLED' THEN
        RAISE NOTICE 'Reservation % already cancelled; nothing released', p_reservation_id;
        RETURN;
    END IF;

    UPDATE lab_sessions
    SET available_workstations = available_workstations + v_count
    WHERE session_id = v_session_id;

    UPDATE reservations
    SET status = 'CANCELLED', cancelled_at = now()
    WHERE reservation_id = p_reservation_id;

    RAISE NOTICE 'Reservation % cancelled; released % workstation(s)',
                 p_reservation_id, v_count;
END $$;

/*_______________Test with the same reservation twice:  ____________________________*/
CALL cancel_reservation(1);   -- Networking: 10 -> 30
CALL cancel_reservation(1);   -- NOTICE: already cancelled, no change

SELECT session_name, available_workstations FROM lab_sessions WHERE session_id = 1;   -- 30, not 50

/*_______________Step 7:Explicit cursor for sessions with few workstations remaining  ____________________________*/

DO $$
DECLARE
    cur_low CURSOR (p_threshold int) FOR
        SELECT session_name, available_workstations
        FROM lab_sessions
        WHERE available_workstations <= p_threshold
        ORDER BY available_workstations, session_name;
    rec record;
BEGIN
    OPEN cur_low(5);
    LOOP
        FETCH cur_low INTO rec;
        EXIT WHEN NOT FOUND;
        RAISE NOTICE 'Few remaining: % (% left)', rec.session_name, rec.available_workstations;
    END LOOP;
    CLOSE cur_low;
END $$;

/*_______________Step 8:Zero workstations handled with EXCEPTION ____________________________*/
DO $$
BEGIN
    CALL reserve_workstations(1, 'Dr. Mwansa', 0);
EXCEPTION
    WHEN invalid_parameter_value THEN
        RAISE NOTICE 'Invalid quantity handled: %', SQLERRM;
END $$;

/*_______________Step 9:Final state ____________________________*/
SELECT session_id, session_name, total_workstations, available_workstations
FROM lab_sessions ORDER BY session_id;

SELECT r.reservation_id, s.session_name, r.lecturer, r.workstations, r.status, r.cancelled_at
FROM reservations r
JOIN lab_sessions s USING (session_id)
ORDER BY r.reservation_id;