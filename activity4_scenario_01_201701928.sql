/*
ICT371 PostgreSQL Scenario Assignment
Student Number: 201701928
Scenario: 1 - University Library Book Loans
*/

DROP TABLE IF EXISTS book_loans; /* Step 1: Tables and sample data*/
DROP TABLE IF EXISTS books;

CREATE TABLE books (
    book_id          serial PRIMARY KEY,
    title            text NOT NULL UNIQUE,
    total_copies     int  NOT NULL CHECK (total_copies > 0),
    available_copies int  NOT NULL,
    CHECK (available_copies BETWEEN 0 AND total_copies)
);

CREATE TABLE book_loans (
    loan_id        serial PRIMARY KEY,
    book_id        int  NOT NULL REFERENCES books(book_id),
    student_number text NOT NULL CHECK (length(btrim(student_number)) > 0),
    quantity       int  NOT NULL CHECK (quantity > 0),
    status         text NOT NULL DEFAULT 'ON_LOAN'
                   CHECK (status IN ('ON_LOAN', 'RETURNED')),
    loaned_at      timestamptz NOT NULL DEFAULT now(),
    returned_at    timestamptz
);

INSERT INTO books (title, total_copies, available_copies) VALUES
    ('Database Systems',  10, 10),
    ('Operating Systems',  6,  4),
    ('Data Structures',    5,  0),
    ('Computer Networks',  8,  2);

/*_______________________________________________________________________________________________*/
/* Step 2: IF / ELSIF / ELSE stock report*/

DO $$
DECLARE
    rec record;
    v_low_limit CONSTANT int := 3;
BEGIN
    FOR rec IN SELECT title, available_copies FROM books ORDER BY book_id LOOP
        IF rec.available_copies = 0 THEN
            RAISE NOTICE '%: UNAVAILABLE', rec.title;
        ELSIF rec.available_copies <= v_low_limit THEN
            RAISE NOTICE '%: LOW on copies (% left)', rec.title, rec.available_copies;
        ELSE
            RAISE NOTICE '%: sufficiently stocked (%)', rec.title, rec.available_copies;
        END IF;
    END LOOP;
END $$;

/*_______________________________________________________________________________________________*/
/* Step 3: WHILE and numeric FOR */

DO $$
DECLARE
    v_reminder int := 1;
BEGIN
    WHILE v_reminder <= 3 LOOP
        RAISE NOTICE 'Overdue reminder number %', v_reminder;
        v_reminder := v_reminder + 1;
    END LOOP;

    FOR shelf IN 1..3 LOOP
        RAISE NOTICE 'Library shelf number %', shelf;
    END LOOP;
END $$;

/*_______________________________________________________________________________________________*/
/* Step 4: borrow_book procedure */

CREATE OR REPLACE PROCEDURE borrow_book(
    p_book_id int,
    p_student text,
    p_qty     int
)
LANGUAGE plpgsql AS $$
DECLARE
    v_available int;
BEGIN
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be at least 1)', p_qty
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_student IS NULL OR btrim(p_student) = '' THEN
        RAISE EXCEPTION 'Student number is required'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- Lock the book row so concurrent loans cannot oversell copies
    SELECT available_copies INTO v_available
    FROM books
    WHERE book_id = p_book_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Book % not found', p_book_id;
    END IF;

    IF v_available < p_qty THEN
        RAISE EXCEPTION 'Insufficient copies: requested %, available %', p_qty, v_available;
    END IF;

    UPDATE books
    SET available_copies = available_copies - p_qty
    WHERE book_id = p_book_id;

    INSERT INTO book_loans (book_id, student_number, quantity)
    VALUES (p_book_id, btrim(p_student), p_qty);

    RAISE NOTICE 'Loaned % cop(ies) of book % to student %',
                 p_qty, p_book_id, btrim(p_student);
END $$;

/*_______________________________________________________________________________________________*/
/* Step 5: borrow_book procedure */

CALL borrow_book(1, '2021001', 3);   -- Database Systems: 10 -> 7
CALL borrow_book(2, '2021002', 2);   -- Operating Systems: 4 -> 2

DO $$
BEGIN
    CALL borrow_book(2, '2021003', 5);   -- only 2 left
EXCEPTION
    WHEN raise_exception THEN
        RAISE NOTICE 'Rejected: %', SQLERRM;
END $$;

SELECT * FROM books ORDER BY book_id;
SELECT * FROM book_loans ORDER BY loan_id;

/*_______________________________________________________________________________________________*/
/* Step 6: return_book procedure */

CREATE OR REPLACE PROCEDURE return_book(p_loan_id int)
LANGUAGE plpgsql AS $$
DECLARE
    v_book_id int;
    v_qty     int;
    v_status  text;
BEGIN
    SELECT book_id INTO v_book_id
    FROM book_loans WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % not found', p_loan_id;
    END IF;

    -- Lock book first, then loan: same order as borrow_book, so no deadlock
    PERFORM 1 FROM books WHERE book_id = v_book_id FOR UPDATE;

    SELECT quantity, status INTO v_qty, v_status
    FROM book_loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF v_status = 'RETURNED' THEN
        RAISE NOTICE 'Loan % already returned; copies unchanged', p_loan_id;
        RETURN;
    END IF;

    UPDATE books
    SET available_copies = available_copies + v_qty
    WHERE book_id = v_book_id;

    UPDATE book_loans
    SET status = 'RETURNED', returned_at = now()
    WHERE loan_id = p_loan_id;

    RAISE NOTICE 'Loan % returned; restored % cop(ies)', p_loan_id, v_qty;
END $$;

/*_______________________________________________________________________________________________*/
/* Test with the same loan twice: */
CALL return_book(1);   -- Database Systems: 7 -> 10
CALL return_book(1);   -- NOTICE: already returned, no change

SELECT title, available_copies FROM books WHERE book_id = 1;   -- 10, not 13

/*_______________________________________________________________________________________________*/
/* Step 7: Explicit cursor for books with few copies remaining */

DO $$
DECLARE
    cur_few CURSOR (p_threshold int) FOR
        SELECT title, available_copies
        FROM books
        WHERE available_copies <= p_threshold
        ORDER BY available_copies, title;
    rec record;
BEGIN
    OPEN cur_few(3);
    LOOP
        FETCH cur_few INTO rec;
        EXIT WHEN NOT FOUND;
        RAISE NOTICE 'Few copies: % (% left)', rec.title, rec.available_copies;
    END LOOP;
    CLOSE cur_few;
END $$;

/*_______________________________________________________________________________________________*/
/* Step 8: Zero copies handled with EXCEPTION */

DO $$
BEGIN
    CALL borrow_book(1, '2021004', 0);
EXCEPTION
    WHEN invalid_parameter_value THEN
        RAISE NOTICE 'Invalid quantity handled: %', SQLERRM;
END $$;

/*_______________________________________________________________________________________________*/
/* Step 9: Final state */

SELECT book_id, title, total_copies, available_copies
FROM books ORDER BY book_id;

SELECT l.loan_id, b.title, l.student_number, l.quantity, l.status, l.returned_at
FROM book_loans l
JOIN books b USING (book_id)
ORDER BY l.loan_id;