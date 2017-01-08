#lang rosette

(require "table.rkt")

(provide gen-sym-schema
         gen-pos-sym-schema
	 sym-tab-constrain
         dedup
         dedup-accum
	 projection
	 cross-prod
	 get-row-count
	 equi-join
	 left-outer-join
	 left-outer-join-2
	 left-outer-join-raw
	 table-diff
	 union-all
	 extend-each-row
         xproduct
         xproduct-raw
	 sqlnull)

(define sqlnull "null-symbol")

;; rawTable -> rawTable -> rawTable
(define (xproduct-raw a b)
  (let ([imr (cartes-prod a b)])
    (map 
      (lambda (x)
	(cons 
	  (append (car (car x)) 
		  (car (second x))) 
	  (* (cdr (car x)) 
	     (cdr (second x))))) 
      imr)))

(define (cartes-prod a b)
  (let ([one-v-many (lambda (x)
                      (map (lambda (e) (list x e)) b))])
    (foldr append '() (map one-v-many a))))

;; Table -> Table -> Table
(define (xproduct a b name)
  (Table name (schema-join a b) (xproduct-raw (Table-content a) (Table-content b))) 
)

; generate a symbolic value
(define (gen-sv)
  (define-symbolic* sv integer?)
  sv)

; generate a tuple, n is the number of column
(define (gen-sv-row n)
  (build-list n (lambda (x) (gen-sv))))

; generate a positive symbolic value, used to represent cardinalities of tuples
(define (gen-pos-sv)
  (define-symbolic* sv-pos integer?)
  (assert (>= sv-pos 0))
  sv-pos)

; generate a positive tuple, n is the number of column
(define (gen-pos-sv-row n)
  (build-list n (lambda (x) (gen-pos-sv))))

; generate a symbolic table of num-col columns and num-row rows
(define (gen-sym-schema num-col num-row)
  (let ([gen-row (lambda (x)
                   (cons (gen-sv-row num-col)
                         (gen-pos-sv)))])
    (build-list num-row gen-row)))

; generate a symbolic table of num-col columns and num-row rows
(define (gen-pos-sym-schema num-col num-row)
  (let ([gen-row (lambda (x)
                   (cons (gen-pos-sv-row num-col)
                         (gen-pos-sv)))])
    (build-list num-row gen-row)))

(define (sym-tab-constrain table)
  (foldl && #t (map (lambda (p) (> (cdr p) 0)) table)))

(define (dedup table)
  (cond
    [(equal? '() table) '()]
    [else 
      (let ([ele (car table)])
	(cond 
	  [(equal? (cdr ele) 0)
	   (dedup (cdr table))]
	  [else 
	    (cons (cons (car ele) 1)
	      (dedup 
		(filter 
		  (lambda (x)
		    (not (equal? (car ele) (car x))))
		  (cdr table))))]))]))

(define (dedup-accum table)
  (cond 
    [(equal? '() table) '()]
    [else 
      (let ([ele (car table)])
	(cons 
	  (cons 
	    (car ele)
	    (foldl + 0
		   (map cdr (filter (lambda (x) (equal? (car ele) (car x))) table))))
	  (dedup-accum 
	    (filter 
	      (lambda (x)
		(not (equal? (car ele) (car x))))
	      (cdr table)))))]))

(define (projection indices table)
  (let ([proj-single (lambda (r)
                       (map (lambda (i)
                              (list-ref r i))
                            indices))])
    (map (lambda (p)
           (cons (proj-single (car p)) (cdr p)))
         table)))

; Given two tables, calculate the difference of table1 and table2 (with considering cardinanity)
(define (table-diff table1 table2)
  (let ([t1 (dedup-accum table1)])
    (map 
      (lambda (r) 
	(cons (car r) 
	      (let ([cnt (- (cdr r) (get-row-count (car r) table2))])
		(cond [(> cnt 0) cnt]
		      [else 0])))) 
      t1)))

; Given a row and a table, count 
(define (get-row-count row-content table-content)
  (foldl + 0
    (map 
      (lambda (r) 
	(cond 
	  [(equal? (car r) row-content) (cdr r)]
	  [else 0]))
      table-content)))

(define (union-all table1 table2)
  (Table (get-table-name table1) 
	 (get-schema table1) 
	 (union-all-raw
	   (Table-content table1)
	   (Table-content table2))))

(define (union-all-raw content1 content2)
  (append content1 content2))

; equi join two tables, given a list of index pairs of form  [(c1, c1'), ..., (cn, cn')] 
; and the join condition is t1.c1 == t2.c1' and ... and t1.cn == t2.cn'
(define (equi-join content1 content2 index-pairs schema-size-1)
  (let ([join-result (xproduct-raw content1 content2)])
    (map (lambda (r)   
	   (cons (car r)
		 (cond [(foldl && #t
			       (map
				 (lambda (p)
				   (equal? 
				     (list-ref (car r) (car p)) 
				     (list-ref (car r) (+ (cdr p) schema-size-1)))) 
				 index-pairs)) 
			(cdr r)]
		       [else 0])))
	 join-result)))

; left outer join on two tables
(define (left-outer-join table1 table2 index1 index2)
  (let* ([content1 (Table-content table1)]
	 [content2 (Table-content table2)])
    (Table 
      (string-append (get-table-name table1)
		     (get-table-name table2))
      (schema-join table1 table2) 
      (left-outer-join-raw content1 content2 index1 index2 (length (get-schema table1)) (length (get-schema table2))))))

; another version of left-outer-join
(define (left-outer-join-2 table1 table2 table12)
  (let* ([content1 (Table-content table1)]
	 [content2 (Table-content table2)]
	 [content12 (Table-content table12)])
    (Table
      (string-append (get-table-name table1)
		     (get-table-name table2))
      (schema-join table1 table2)
      (adding-null-rows content1 content2 content12 (length (get-schema table1)) (length (get-schema table2))))))


; left outer join two tables based on index1 and index2, this is raw because content1 content2 contains no table schema
(define (left-outer-join-raw content1 content2 index1 index2 schema-size-1 schema-size-2)
  (let ([content12 (equi-join content1 content2 (list (cons index1 index2)) schema-size-1)])
    (adding-null-rows content1 content2 content12 schema-size-1 schema-size-2)))

; content12 is the join result of content1 and content2 under come condition, 
;this functions helps extending the join result with rows in content1 but not in content 2
(define (adding-null-rows content1 content2 content12 schema-size-1 schema-size-2)
  (let ([null-cols (map (lambda (x) sqlnull) (build-list schema-size-2 values))])
    (let ([diff-keys (dedup (table-diff (dedup content1) (dedup (projection (build-list schema-size-1 values) content12))))])
      (let ([extra-rows (projection (build-list schema-size-1 values) (equi-join content1 diff-keys (build-list schema-size-1 (lambda (x) (cons x x))) schema-size-1))])
        (union-all-raw 
	  content12
	  (map (lambda (r) (cons (append (car r) null-cols) (cdr r))) extra-rows))))))

; extend each row in the table with extended-element-list,
; e.g. each row will be (row ++ eel)
(define (extend-each-row table extra-elements)
  (map (lambda (r) (cons (append (car r) extra-elements) (cdr r))) table))

(define (cross-prod table1 table2)
  (let ([cross-single (lambda (p1)
                        (map (lambda (p2)
                               (let ([r1 (car p1)]
                                     [r2 (car p2)]
                                     [cnt (* (cdr p1) (cdr p2))])
                                 (cons (append r1 r2) cnt)))
                             table2))])
    (foldr append '() (map cross-single table1))))

;; several test xproduct
(define content-a
  (list
    (cons (list 1 1 2) 2)
    (cons (list 0 1 2) 2)))

(define content-b
  (list
    (cons (list 1 2 3) 1)
    (cons (list 2 1 0) 3)))

(define content-d
  (list
    (cons (list 1 2 3) 2)
    (cons (list 2 3 3) 3)))

(define content-ab
  (list
    (cons (list 1 1 2 2 1 0) 6)))

(define content-c
  (list))

(define table-a
  (Table "a" (list "a" "b" "c") content-a))

(define table-b
  (Table "b" (list "a" "b" "c") content-b))

(define table-ab
  (Table "ab" (list "a" "b" "c" "a" "b" "c") content-ab))

; tests
; (println (xproduct table-a table-b 'c))
; (println (xproduct-raw content-a content-b))
; (println (get-content (left-outer-join table-a table-b 2 2)))
; (left-outer-join-raw content-c content-c 0 0 3 3)