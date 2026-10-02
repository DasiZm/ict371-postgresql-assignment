/*
ICT371 PostgreSQL Scenario Assignment
Student Number: 201701928
Scenario: 3 - Student Hostel Room Allocation
*/
/*_______________Step 1:Tables and sample data  ____________________________*/
DROP TABLE IF EXISTS allocations;
DROP TABLE IF EXISTS hostel_rooms;

CREATE TABLE hostel_rooms (
    room_id          serial PRIMARY KEY,
    room_name        text NOT NULL UNIQUE,
    total_spaces     int  NOT NULL CHECK (total_spaces > 0),
    available_spaces int  NOT NULL,
    CHECK (available_spaces BETWEEN 0 AND total_spaces)
);

CREATE TABLE allocations (
    allocation_id  serial PRIMARY KEY,
    room_id        int  NOT NULL REFERENCES hostel_rooms(room_id),
    student_number text NOT NULL CHECK (length(btrim(student_number)) > 0),
    status         text NOT NULL DEFAULT 'ACTIVE'
                   CHECK (status IN ('ACTIVE', 'COMPLETED')),
    allocated_at   timestamptz NOT NULL DEFAULT now(),
    checked_out_at timestamptz
);

-- A student can hold only one active bed space at a time
CREATE UNIQUE INDEX one_active_allocation_per_student
    ON allocations (student_number) WHERE status = 'ACTIVE';

INSERT INTO hostel_rooms (room_name, total_spaces, available_spaces) VALUES
    ('A101', 4, 4),
    ('A102', 2, 1),
    ('B201', 2, 0),
    ('B202', 3, 3);

/*_______________Step 2:IF / ELSIF / ELSE room report  ____________________________*/

DO $$
DECLARE
    rec record;
BEGIN
    FOR rec IN SELECT room_name, available_spaces FROM hostel_rooms ORDER BY room_id LOOP
        IF rec.available_spaces = 0 THEN
            RAISE NOTICE 'Room %: FULL', rec.room_name;
        ELSIF rec.available_spaces = 1 THEN
            RAISE NOTICE 'Room %: ONE space left', rec.room_name;
        ELSE
            RAISE NOTICE 'Room %: several spaces (%)', rec.room_name, rec.available_spaces;
        END IF;
    END LOOP;
END $$;

/*_______________Step 3:WHILE and numeric FOR  ____________________________*/

DO $$
DECLARE
    v_day int := 1;
BEGIN
    WHILE v_day <= 3 LOOP
        RAISE NOTICE 'Hostel inspection day %', v_day;
        v_day := v_day + 1;
    END LOOP;

    FOR i IN 1..3 LOOP
        RAISE NOTICE 'Room check #%', i;
    END LOOP;
END $$;

/*_______________Step 4:allocate_room procedure  ____________________________*/

CREATE OR REPLACE PROCEDURE allocate_room(p_student text, p_room_id int)
LANGUAGE plpgsql AS $$
DECLARE
    v_available int;
BEGIN
    IF p_student IS NULL OR btrim(p_student) = '' THEN
        RAISE EXCEPTION 'Student number is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Lock the room so two simultaneous allocations cannot take the last space
    SELECT available_spaces INTO v_available
    FROM hostel_rooms
    WHERE room_id = p_room_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Room % not found', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_number = btrim(p_student) AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an active allocation', btrim(p_student);
    END IF;

    IF v_available < 1 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;

    UPDATE hostel_rooms
    SET available_spaces = available_spaces - 1
    WHERE room_id = p_room_id;

    INSERT INTO allocations (room_id, student_number)
    VALUES (p_room_id, btrim(p_student));

    RAISE NOTICE 'Allocated student % to room %', btrim(p_student), p_room_id;
END $$;

/*_______________Step 5:Two valid calls, one to a full room  ____________________________*/

CALL allocate_room('2021001', 1);   -- A101: 4 -> 3
CALL allocate_room('2021002', 4);   -- B202: 3 -> 2

DO $$
BEGIN
    CALL allocate_room('2021003', 3);   -- B201 is full
EXCEPTION
    WHEN raise_exception THEN
        RAISE NOTICE 'Rejected: %', SQLERRM;
END $$;

SELECT * FROM hostel_rooms ORDER BY room_id;
SELECT * FROM allocations ORDER BY allocation_id;

/*_______________Step 6:check_out procedure  ____________________________*/

CREATE OR REPLACE PROCEDURE check_out(p_allocation_id int)
LANGUAGE plpgsql AS $$
DECLARE
    v_room_id int;
    v_status  text;
BEGIN
    SELECT room_id INTO v_room_id
    FROM allocations WHERE allocation_id = p_allocation_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Allocation % not found', p_allocation_id;
    END IF;

    -- Lock room first, then allocation: same order as allocate_room, so no deadlock
    PERFORM 1 FROM hostel_rooms WHERE room_id = v_room_id FOR UPDATE;

    SELECT status INTO v_status
    FROM allocations
    WHERE allocation_id = p_allocation_id
    FOR UPDATE;

    IF v_status = 'COMPLETED' THEN
        RAISE NOTICE 'Allocation % already completed; no space released', p_allocation_id;
        RETURN;
    END IF;

    UPDATE hostel_rooms
    SET available_spaces = available_spaces + 1
    WHERE room_id = v_room_id;

    UPDATE allocations
    SET status = 'COMPLETED', checked_out_at = now()
    WHERE allocation_id = p_allocation_id;

    RAISE NOTICE 'Allocation % completed; space released in room %',
                 p_allocation_id, v_room_id;
END $$;

/*_______________Test with the same allocation twice:  ____________________________*/
CALL check_out(1);   -- A101: 3 -> 4
CALL check_out(1);   -- NOTICE: already completed, no change

SELECT room_name, available_spaces FROM hostel_rooms WHERE room_id = 1;   -- 4, not 5

/*_______________Step 7:Explicit cursor for full or nearly full rooms  ____________________________*/

DO $$
DECLARE
    cur_rooms CURSOR (p_max_free int) FOR
        SELECT room_name, available_spaces
        FROM hostel_rooms
        WHERE available_spaces <= p_max_free
        ORDER BY available_spaces, room_name;
    rec record;
BEGIN
    OPEN cur_rooms(1);   -- full (0) or nearly full (1)
    LOOP
        FETCH cur_rooms INTO rec;
        EXIT WHEN NOT FOUND;
        IF rec.available_spaces = 0 THEN
            RAISE NOTICE 'FULL: %', rec.room_name;
        ELSE
            RAISE NOTICE 'NEARLY FULL: % (% space left)', rec.room_name, rec.available_spaces;
        END IF;
    END LOOP;
    CLOSE cur_rooms;
END $$;

/*_______________Step 8:Blank student number handled with EXCEPTION ____________________________*/

DO $$
BEGIN
    CALL allocate_room('   ', 1);
EXCEPTION
    WHEN invalid_parameter_value THEN
        RAISE NOTICE 'Invalid input handled: %', SQLERRM;
END $$;

/*_______________Step 9:Final state ____________________________*/

SELECT room_id, room_name, total_spaces, available_spaces
FROM hostel_rooms ORDER BY room_id;

SELECT a.allocation_id, r.room_name, a.student_number, a.status, a.checked_out_at
FROM allocations a
JOIN hostel_rooms r USING (room_id)
ORDER BY a.allocation_id;