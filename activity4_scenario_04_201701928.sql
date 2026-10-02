/*

ICT371 PostgreSQL Scenario Assignment
Student Number: 201701928
Scenario: 4 - Campus Clinic Medicine Dispensing

*/
/*_______________Step 1:Tables and sample data  ____________________________*/

DROP TABLE IF EXISTS dispensing_records;
DROP TABLE IF EXISTS medicines;

CREATE TABLE medicines (
    medicine_id   serial PRIMARY KEY,
    medicine_name text NOT NULL UNIQUE,
    stock_qty     int  NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE dispensing_records (
    record_id      serial PRIMARY KEY,
    medicine_id    int  NOT NULL REFERENCES medicines(medicine_id),
    student_number text NOT NULL,
    quantity       int  NOT NULL CHECK (quantity > 0),
    status         text NOT NULL DEFAULT 'DISPENSED'
                   CHECK (status IN ('DISPENSED', 'REVERSED')),
    dispensed_at   timestamptz NOT NULL DEFAULT now(),
    reversed_at    timestamptz
);

INSERT INTO medicines (medicine_name, stock_qty) VALUES
    ('Paracetamol 500mg', 100),
    ('Amoxicillin 250mg',   8),
    ('ORS Sachets',         0),
    ('Ibuprofen 200mg',    40);

/*_______________Step 2: IF / ELSIF / ELSE stock report  ____________________________*/

DO $$
DECLARE
    v_name      text := 'Amoxicillin 250mg';
    v_stock     int;
    v_low_limit CONSTANT int := 10;
BEGIN
    SELECT stock_qty INTO v_stock
    FROM medicines WHERE medicine_name = v_name;

    IF NOT FOUND THEN
        RAISE NOTICE '% does not exist', v_name;
    ELSIF v_stock = 0 THEN
        RAISE NOTICE '%: OUT OF STOCK', v_name;
    ELSIF v_stock <= v_low_limit THEN
        RAISE NOTICE '%: LOW STOCK (% units)', v_name, v_stock;
    ELSE
        RAISE NOTICE '%: sufficiently stocked (% units)', v_name, v_stock;
    END IF;
END $$;

/*_______________Step 3: WHILE and numeric FOR ____________________________*/

DO $$
DECLARE
    v_day int := 1;
BEGIN
    WHILE v_day <= 3 LOOP
        RAISE NOTICE 'Stock review day %', v_day;
        v_day := v_day + 1;
    END LOOP;

    FOR i IN 1..3 LOOP
        RAISE NOTICE 'Shelf inspection #%', i;
    END LOOP;
END $$;

/*_______________Step 4: dispense_medicine procedure ____________________________*/

CREATE OR REPLACE PROCEDURE dispense_medicine(
    p_medicine_id int,
    p_student     text,
    p_qty         int
)
LANGUAGE plpgsql AS $$
DECLARE
    v_stock int;
BEGIN
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be positive)', p_qty
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Lock the row so concurrent dispensing cannot oversell
    SELECT stock_qty INTO v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Medicine % not found', p_medicine_id;
    END IF;

    IF v_stock < p_qty THEN
        RAISE EXCEPTION 'Insufficient stock: requested %, available %', p_qty, v_stock;
    END IF;

    UPDATE medicines
    SET stock_qty = stock_qty - p_qty
    WHERE medicine_id = p_medicine_id;

    INSERT INTO dispensing_records (medicine_id, student_number, quantity)
    VALUES (p_medicine_id, p_student, p_qty);

    RAISE NOTICE 'Dispensed % unit(s) of medicine % to student %',
                 p_qty, p_medicine_id, p_student;
END $$;

/*_______________Step 5: Two valid calls, one invalid ____________________________*/

CALL dispense_medicine(1, '2021001', 20);   -- Paracetamol: 100 -> 80
CALL dispense_medicine(2, '2021002', 3);    -- Amoxicillin: 8 -> 5

DO $$
BEGIN
    CALL dispense_medicine(2, '2021003', 50);   -- exceeds stock of 5
EXCEPTION
    WHEN raise_exception THEN
        RAISE NOTICE 'Rejected: %', SQLERRM;
END $$;

SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM dispensing_records ORDER BY record_id;

/*_______________Step 6: reverse_dispensing procedure ____________________________*/

CREATE OR REPLACE PROCEDURE reverse_dispensing(p_record_id int)
LANGUAGE plpgsql AS $$
DECLARE
    v_medicine_id int;
    v_qty         int;
    v_status      text;
BEGIN
    -- Lock the record: two simultaneous reversals cannot both pass the status check
    SELECT medicine_id, quantity, status
    INTO v_medicine_id, v_qty, v_status
    FROM dispensing_records
    WHERE record_id = p_record_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Dispensing record % not found', p_record_id;
    END IF;

    IF v_status = 'REVERSED' THEN
        RAISE NOTICE 'Record % already reversed; stock unchanged', p_record_id;
        RETURN;
    END IF;

    UPDATE medicines
    SET stock_qty = stock_qty + v_qty
    WHERE medicine_id = v_medicine_id;

    UPDATE dispensing_records
    SET status = 'REVERSED', reversed_at = now()
    WHERE record_id = p_record_id;

    RAISE NOTICE 'Record % reversed; restored % unit(s)', p_record_id, v_qty;
END $$;

/*_______________Test with the same record twice: ____________________________*/

CALL reverse_dispensing(1);   -- restores 20: Paracetamol 80 -> 100
CALL reverse_dispensing(1);   -- NOTICE: already reversed, no change

SELECT medicine_name, stock_qty FROM medicines WHERE medicine_id = 1;   -- 100, not 120

/*_______________Step 7: Explicit cursor for low stock ____________________________*/

DO $$
DECLARE
    cur_low CURSOR (p_threshold int) FOR
        SELECT medicine_name, stock_qty
        FROM medicines
        WHERE stock_qty < p_threshold
        ORDER BY stock_qty;
    rec record;
BEGIN
    OPEN cur_low(10);
    LOOP
        FETCH cur_low INTO rec;
        EXIT WHEN NOT FOUND;
        RAISE NOTICE 'Below threshold: % (% units)', rec.medicine_name, rec.stock_qty;
    END LOOP;
    CLOSE cur_low;
END $$;

/*_______________Step 8: Negative quantity handled with EXCEPTION ____________________________*/

DO $$
BEGIN
    CALL dispense_medicine(1, '2021004', -5);
EXCEPTION
    WHEN invalid_parameter_value THEN
        RAISE NOTICE 'Invalid input handled: %', SQLERRM;
END $$;

/*_______________Step 9: Final state ____________________________*/

SELECT medicine_id, medicine_name, stock_qty
FROM medicines ORDER BY medicine_id;

SELECT r.record_id, m.medicine_name, r.student_number, r.quantity, r.status, r.reversed_at
FROM dispensing_records r
JOIN medicines m USING (medicine_id)
ORDER BY r.record_id;