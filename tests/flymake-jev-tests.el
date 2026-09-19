;;; flymake-jev-tests.el --- Tests for flymake-jev.el -*- lexical-binding: t; -*-

;;; Commentary:

;; The transport is replaced through `jev-http-function', so the real
;; path from a rule to a question to an answer is exercised and only
;; the socket is missing.  Flymake itself is mostly kept out of it: the
;; backend is called directly with a report function that records what
;; it was given, which is both faster and more exact than reading
;; overlays back out of a buffer.

;;; Code:

(require 'ert)
(require 'seq)
(require 'flymake-jev)

(defvar flymake-jev-tests--requests nil
  "Decoded request bodies, newest first.")

(defvar flymake-jev-tests--answers 0.9
  "What the stub answers: a probability for every question, or an alist by ID.")

(defvar flymake-jev-tests--held nil
  "Callbacks of requests the holding stub has not answered yet, oldest first.")

(defvar flymake-jev-tests--results nil
  "Results the stub returns instead of an answer, one per request.")

(defun flymake-jev-tests--questions (body)
  "Return the question ids in the decoded request BODY."
  (mapcar #'car (alist-get 'questions body)))

(defun flymake-jev-tests--state (body)
  "Return the state of the decoded request BODY."
  (alist-get 'state body))

(defun flymake-jev-tests--probability (id)
  "Return what the stub answers for question ID."
  (if (numberp flymake-jev-tests--answers)
      flymake-jev-tests--answers
    (or (alist-get id flymake-jev-tests--answers) 0)))

(defun flymake-jev-tests--result (body)
  "Return a 200 result answering every question in the decoded BODY."
  (list :status 200 :headers nil
        :body (format "{\"answers\":{%s}}"
                      (mapconcat
                       (lambda (id)
                         (format "\"%s\":{\"type\":\"noul\",\"noul\":%s}"
                                 id (flymake-jev-tests--probability id)))
                       (flymake-jev-tests--questions body)
                       ","))))

(defun flymake-jev-tests--stub ()
  "Return a transport answering each request as soon as it is made."
  (lambda (_url _headers body _timeout sync callback)
    (let ((decoded (json-parse-string body :object-type 'alist)))
      (push decoded flymake-jev-tests--requests)
      (let ((result (or (pop flymake-jev-tests--results)
                        (flymake-jev-tests--result decoded))))
        (if sync result (progn (funcall callback result) nil))))))

(defun flymake-jev-tests--holding-stub ()
  "Return a transport that records requests and answers none of them."
  (lambda (_url _headers body _timeout _sync callback)
    (let ((decoded (json-parse-string body :object-type 'alist)))
      (push decoded flymake-jev-tests--requests)
      (setq flymake-jev-tests--held
            (append flymake-jev-tests--held (list (cons decoded callback))))
      (lambda () nil))))

(defun flymake-jev-tests--release ()
  "Answer the oldest request the holding stub is sitting on."
  (let ((held (pop flymake-jev-tests--held)))
    (should held)
    (funcall (cdr held) (flymake-jev-tests--result (car held)))))

(defun flymake-jev-tests--settle (&optional predicate)
  "Run timers until PREDICATE holds, or a moment passes.
Every jev callback is delivered from a timer, so nothing has
happened until the timers have run."
  (let ((deadline (+ (float-time) 2)))
    (while (and (not (and predicate (funcall predicate)))
                (< (float-time) deadline))
      (sleep-for 0.01)
      (unless predicate
        (setq deadline (min deadline (+ (float-time) 0.05)))))))

(defmacro flymake-jev-tests--with-buffer (setup &rest body)
  "Run BODY in a temp buffer prepared by SETUP, with the transport stubbed."
  (declare (indent 1))
  `(let ((flymake-jev-tests--requests nil)
         (flymake-jev-tests--held nil)
         (flymake-jev-tests--results nil)
         (flymake-jev-tests--answers 0.9)
         (jev-api-key "test-key")
         (jev-retry-initial-delay 0)
         (flymake-jev-trigger 'change)
         (flymake-jev-calibrated-thresholds nil)
         (jev-http-function (flymake-jev-tests--stub)))
     (with-temp-buffer
       ,setup
       ,@body)))

(defvar flymake-jev-tests--reports nil
  "Everything the backend reported, newest first, as (DIAGNOSTICS . ARGS).")

(defun flymake-jev-tests--report-fn ()
  "Return a report function that records what it is given."
  (lambda (diagnostics &rest args)
    (push (cons diagnostics args) flymake-jev-tests--reports)))

(defun flymake-jev-tests--run ()
  "Run the backend once, recording its reports, and settle the timers."
  (setq flymake-jev-tests--reports nil)
  (flymake-jev (flymake-jev-tests--report-fn))
  (flymake-jev-tests--settle)
  (reverse flymake-jev-tests--reports))

(defun flymake-jev-tests--texts (reports)
  "Return the text of every diagnostic in REPORTS."
  (mapcar #'flymake-diagnostic-text
          (apply #'append (mapcar (lambda (report)
                                    (and (listp (car report)) (car report)))
                                  reports))))

(defconst flymake-jev-tests--paragraph
  "A paragraph long enough to be worth asking about, with more than forty characters in it."
  "Text that clears `flymake-jev-min-chars'.")


;;;; Units

(ert-deftest flymake-jev-test-paragraphs-are-units ()
  (with-temp-buffer
    (text-mode)
    (insert flymake-jev-tests--paragraph "\n\n"
            "   \n"
            flymake-jev-tests--paragraph "\n")
    (let ((units (flymake-jev-text-units)))
      (should (= (length units) 2))
      (dolist (unit units)
        (should (equal (flymake-jev--unit-text unit) flymake-jev-tests--paragraph))))))

(ert-deftest flymake-jev-test-short-units-are-dropped ()
  (with-temp-buffer
    (text-mode)
    (insert "Too short.\n\n" flymake-jev-tests--paragraph "\n")
    (should (= (length (flymake-jev-text-units)) 2))
    (should (= (length (flymake-jev--units)) 1))
    ;; A whitespace-only buffer has nothing in it either way.
    (erase-buffer)
    (insert "\n \n\t\n")
    (should-not (flymake-jev-text-units))))

(ert-deftest flymake-jev-test-defuns-are-units ()
  (with-temp-buffer
    (emacs-lisp-mode)
    (insert "(defun one ()\n  \"A docstring that is long enough to count.\"\n  1)\n\n"
            "(defun two ()\n  \"Another docstring that is long enough to count.\"\n  2)\n")
    (let ((units (flymake-jev--units)))
      (should (= (length units) 2))
      (should (string-prefix-p "(defun one" (flymake-jev--unit-text (car units))))
      (should (string-suffix-p "2)" (flymake-jev--unit-text (cadr units)))))))

(ert-deftest flymake-jev-test-a-commit-message-is-one-unit ()
  (with-temp-buffer
    (text-mode)
    (setq-local comment-start "#")
    (setq-local git-commit-mode t)
    (insert "Add the thing\n\n"
            "The body explains why the thing had to be added at all.\n"
            "# Please enter the commit message for your changes.\n"
            "# On branch main\n")
    (let ((units (flymake-jev--units)))
      (should (= (length units) 1))
      (should (equal (flymake-jev--unit-text (car units))
                     (concat "Add the thing\n\n"
                             "The body explains why the thing had to be added at all.")))
      (should (equal (flymake-jev--kind) "commit message")))))


;;;; Rules in force

(ert-deftest flymake-jev-test-rules-of-a-parent-mode-apply ()
  (let ((flymake-jev-rules '((text-mode (hedge "Does it hedge?"))
                             (org-mode (link "Is the link bare?")))))
    (with-temp-buffer
      (org-mode)
      (should (equal (mapcar #'car (flymake-jev--rules)) '(hedge link))))
    (with-temp-buffer
      (text-mode)
      (should (equal (mapcar #'car (flymake-jev--rules)) '(hedge))))
    (with-temp-buffer
      (emacs-lisp-mode)
      (should-not (flymake-jev--rules)))))

(ert-deftest flymake-jev-test-a-minor-mode-can-carry-rules ()
  (let ((flymake-jev-rules '((git-commit-mode (imperative "Is it imperative?")))))
    (with-temp-buffer
      (text-mode)
      (should-not (flymake-jev--rules))
      (setq-local git-commit-mode t)
      (should (equal (mapcar #'car (flymake-jev--rules)) '(imperative))))))

(ert-deftest flymake-jev-test-a-repeated-id-keeps-the-later-rule ()
  (let ((flymake-jev-rules '((text-mode (hedge "The first one.") (other "Other?"))
                             (org-mode (hedge "The second one.")))))
    (with-temp-buffer
      (org-mode)
      (let ((rules (flymake-jev--rules)))
        (should (equal (mapcar #'car rules) '(other hedge)))
        (should (equal (flymake-jev--rule-instructions (assq 'hedge rules))
                       "The second one."))))))

(ert-deftest flymake-jev-test-extra-rules-add-to-the-global-ones ()
  (let ((flymake-jev-rules '((text-mode (hedge "Does it hedge?")))))
    (with-temp-buffer
      (text-mode)
      (setq-local flymake-jev-extra-rules '((text-mode (house "Is it house style?"))))
      (should (equal (mapcar #'car (flymake-jev--rules)) '(hedge house))))))

(ert-deftest flymake-jev-test-safe-rules-are-recognised ()
  (should (flymake-jev-rules-p '((text-mode (hedge "Does it hedge?" :severity :note)))))
  (should (flymake-jev-rules-p
           '((text-mode (hedge "Does it hedge?"
                               :criteria (("true" . "It hedges") ("false" . "It states")))))))
  (should (flymake-jev-rules-p nil))
  ;; A rule that could run something, or that is not a rule at all.
  (should-not (flymake-jev-rules-p '((text-mode (hedge "?" :severity (delete-file "x"))))))
  (should-not (flymake-jev-rules-p '((text-mode (hedge "?" :unknown t)))))
  (should-not (flymake-jev-rules-p '((text-mode (hedge 42)))))
  (should-not (flymake-jev-rules-p '((text-mode ("hedge" "Does it hedge?")))))
  (should-not (flymake-jev-rules-p '("text-mode")))
  (should (eq (get 'flymake-jev-rules 'safe-local-variable) #'flymake-jev-rules-p)))


;;;; Reporting

(ert-deftest flymake-jev-test-a-buffer-without-rules-is-still-reported-on ()
  (flymake-jev-tests--with-buffer
      (progn (text-mode) (insert flymake-jev-tests--paragraph))
    (let ((flymake-jev-rules nil))
      (let ((reports (flymake-jev-tests--run)))
        (should (= (length reports) 1))
        (should-not (car (car reports)))
        (should-not flymake-jev-tests--requests)))))

(ert-deftest flymake-jev-test-a-broken-rule-panics-and-names-itself ()
  (flymake-jev-tests--with-buffer
      (progn (text-mode) (insert flymake-jev-tests--paragraph))
    (let ((flymake-jev-rules '((text-mode (fine "A fine question?") (broken "")))))
      (let* ((reports (flymake-jev-tests--run))
             (report (car reports)))
        (should (eq (car report) :panic))
        (should (string-match-p "broken" (plist-get (cdr report) :explanation)))
        (should-not flymake-jev-tests--requests)))))

(ert-deftest flymake-jev-test-only-probabilities-above-the-threshold-are-reported ()
  (flymake-jev-tests--with-buffer
      (progn (text-mode) (insert flymake-jev-tests--paragraph))
    (let ((flymake-jev-rules '((text-mode (loud "Is it loud?") (quiet "Is it quiet?"))))
          (flymake-jev-tests--answers '((loud . 0.83) (quiet . 0.2))))
      (let ((texts (flymake-jev-tests--texts (flymake-jev-tests--run))))
        (should (= (length texts) 1))
        (should (equal (car texts) "loud (0.83): Is it loud?"))))))

(ert-deftest flymake-jev-test-thresholds-are-taken-in-order ()
  (flymake-jev-tests--with-buffer
      (progn (text-mode) (insert flymake-jev-tests--paragraph))
    (let ((flymake-jev-rules '((text-mode (loud "Is it loud?"))))
          (flymake-jev-tests--answers '((loud . 0.75))))
      ;; The default lets it through.
      (should (= (length (flymake-jev-tests--texts (flymake-jev-tests--run))) 1))
      ;; The rule's own threshold beats the default.
      (setq flymake-jev-rules '((text-mode (loud "Is it loud?" :threshold 0.8))))
      (should-not (flymake-jev-tests--texts (flymake-jev-tests--run)))
      ;; A fitted threshold beats the rule's own.
      (let ((flymake-jev-calibrated-thresholds '((loud . 0.5))))
        (should (= (length (flymake-jev-tests--texts (flymake-jev-tests--run))) 1))))))

(ert-deftest flymake-jev-test-severity-and-message-reach-the-diagnostic ()
  (flymake-jev-tests--with-buffer
      (progn (text-mode) (insert flymake-jev-tests--paragraph))
    (let ((flymake-jev-rules
           '((text-mode (jargon "Would a newcomer need a term defined?"
                                :severity :note :message "Undefined jargon")))))
      (let* ((reports (flymake-jev-tests--run))
             (diagnostic (car (apply #'append (mapcar #'car (cdr reports))))))
        (should (eq (flymake-diagnostic-type diagnostic) :note))
        (should (equal (flymake-diagnostic-text diagnostic) "jargon (0.90): Undefined jargon"))
        (should (eq (plist-get (flymake-jev-diagnostic-data diagnostic) :rule) 'jargon))))))

(ert-deftest flymake-jev-test-an-answer-is-reported-for-its-own-region ()
  (skip-unless flymake-jev--region-reports-p)
  (flymake-jev-tests--with-buffer
      (progn (text-mode) (insert flymake-jev-tests--paragraph))
    (let ((flymake-jev-rules '((text-mode (loud "Is it loud?")))))
      (let* ((reports (flymake-jev-tests--run))
             (last (car (last reports))))
        (should (equal (plist-get (cdr last) :region) (cons (point-min) (point-max))))))))

(ert-deftest flymake-jev-test-the-state-holds-the-unit-and-nothing-else ()
  (flymake-jev-tests--with-buffer
      (progn (text-mode) (insert flymake-jev-tests--paragraph))
    (let ((flymake-jev-rules '((text-mode (loud "Is it loud?")))))
      (flymake-jev-tests--run)
      (let ((state (flymake-jev-tests--state (car flymake-jev-tests--requests))))
        (should (equal (alist-get 'kind state) "paragraph"))
        (should (equal (alist-get 'language state) "text"))
        (should (equal (alist-get 'text state) flymake-jev-tests--paragraph))
        (should (= (length state) 3))))))


;;;; Asking, and not asking

(ert-deftest flymake-jev-test-an-answer-is-asked-for-once ()
  (flymake-jev-tests--with-buffer
      (progn (text-mode) (insert flymake-jev-tests--paragraph))
    (let ((flymake-jev-rules '((text-mode (loud "Is it loud?")))))
      (flymake-jev-tests--run)
      (should (= (length flymake-jev-tests--requests) 1))
      ;; Same text, same rules: the cache answers.
      (should (= (length (flymake-jev-tests--texts (flymake-jev-tests--run))) 1))
      (should (= (length flymake-jev-tests--requests) 1))
      ;; A rule that has changed is a different question.
      (setq flymake-jev-rules '((text-mode (loud "Is it very loud?"))))
      (flymake-jev-tests--run)
      (should (= (length flymake-jev-tests--requests) 2)))))

(ert-deftest flymake-jev-test-a-modified-buffer-is-not-asked-about ()
  (flymake-jev-tests--with-buffer
      (progn (text-mode) (insert flymake-jev-tests--paragraph))
    (let ((flymake-jev-rules '((text-mode (loud "Is it loud?"))))
          (flymake-jev-trigger 'save))
      (set-buffer-modified-p t)
      (let ((reports (flymake-jev-tests--run)))
        (should (= (length reports) 1))
        (should-not flymake-jev-tests--requests))
      ;; Saved: now it asks, and what it learns is reported.
      (set-buffer-modified-p nil)
      (should (= (length (flymake-jev-tests--texts (flymake-jev-tests--run))) 1))
      (should (= (length flymake-jev-tests--requests) 1))
      ;; Modified again, the cached answer is still reported.
      (set-buffer-modified-p t)
      (should (= (length (flymake-jev-tests--texts (flymake-jev-tests--run))) 1))
      (should (= (length flymake-jev-tests--requests) 1)))))

(ert-deftest flymake-jev-test-check-buffer-asks-whatever-the-trigger-says ()
  (flymake-jev-tests--with-buffer
      (progn (text-mode) (insert flymake-jev-tests--paragraph))
    (let ((flymake-jev-rules '((text-mode (loud "Is it loud?"))))
          (flymake-jev-trigger 'save))
      (set-buffer-modified-p t)
      (let ((flymake-jev--force t))
        (flymake-jev-tests--run))
      (should (= (length flymake-jev-tests--requests) 1)))))

(ert-deftest flymake-jev-test-an-answer-about-text-that-changed-is-dropped ()
  (flymake-jev-tests--with-buffer
      (progn (text-mode) (insert flymake-jev-tests--paragraph))
    (let ((flymake-jev-rules '((text-mode (loud "Is it loud?"))))
          (jev-http-function (flymake-jev-tests--holding-stub)))
      (setq flymake-jev-tests--reports nil)
      (flymake-jev (flymake-jev-tests--report-fn))
      (should (= (length flymake-jev-tests--held) 1))
      ;; The paragraph is rewritten while the question is in flight.
      (goto-char (point-max))
      (insert " And then something else entirely was said instead.")
      (flymake-jev-tests--release)
      (flymake-jev-tests--settle)
      (should-not (flymake-jev-tests--texts (reverse flymake-jev-tests--reports)))
      (should (zerop (hash-table-count (flymake-jev--cache)))))))

(ert-deftest flymake-jev-test-requests-are-queued-up-to-the-limit ()
  (flymake-jev-tests--with-buffer
      (progn (text-mode)
             (dotimes (i 3)
               (insert (format "%s Number %d.\n\n" flymake-jev-tests--paragraph i))))
    (let ((flymake-jev-rules '((text-mode (loud "Is it loud?"))))
          (flymake-jev-max-in-flight 2)
          (jev-http-function (flymake-jev-tests--holding-stub)))
      (setq flymake-jev-tests--reports nil)
      (flymake-jev (flymake-jev-tests--report-fn))
      (should (= (length flymake-jev-tests--requests) 2))
      (should (= (length flymake-jev--queue) 1))
      (flymake-jev-tests--release)
      (flymake-jev-tests--settle (lambda () (= (length flymake-jev-tests--requests) 3)))
      (should (= (length flymake-jev-tests--requests) 3))
      (should-not flymake-jev--queue))))

(ert-deftest flymake-jev-test-more-units-than-allowed-are-left-for-later ()
  (with-temp-buffer
    (text-mode)
    (dotimes (i 3)
      (insert (format "%s Number %d.\n\n" flymake-jev-tests--paragraph i)))
    (let ((flymake-jev-max-units 2))
      (should (= (length (flymake-jev--units)) 2)))))

(ert-deftest flymake-jev-test-a-killed-buffer-abandons-its-requests ()
  (let ((flymake-jev-tests--requests nil)
        (flymake-jev-tests--held nil)
        (jev-api-key "test-key")
        (flymake-jev-trigger 'change)
        (jev-http-function (flymake-jev-tests--holding-stub))
        (flymake-jev-rules '((text-mode (loud "Is it loud?"))))
        (buffer (generate-new-buffer " *flymake-jev-test*"))
        (in-flight nil))
    (unwind-protect
        (with-current-buffer buffer
          (text-mode)
          (insert flymake-jev-tests--paragraph)
          (flymake-jev-setup)
          (flymake-jev (flymake-jev-tests--report-fn))
          (setq in-flight (copy-sequence flymake-jev--requests))
          (should in-flight))
      (kill-buffer buffer))
    (should (seq-every-p #'jev-request-cancelled in-flight))))


;;;; Failures

(ert-deftest flymake-jev-test-an-error-that-will-not-pass-panics ()
  (flymake-jev-tests--with-buffer
      (progn (text-mode) (insert flymake-jev-tests--paragraph))
    (let ((flymake-jev-rules '((text-mode (loud "Is it loud?"))))
          (flymake-jev-tests--results
           (list (list :status 401 :headers nil
                       :body "{\"message\":\"Invalid API key\"}"))))
      (let* ((reports (flymake-jev-tests--run))
             (last (car (last reports))))
        (should (eq (car last) :panic))
        (should (string-match-p "Invalid API key" (plist-get (cdr last) :explanation)))))))

(ert-deftest flymake-jev-test-a-passing-failure-is-only-logged ()
  (flymake-jev-tests--with-buffer
      (progn (text-mode) (insert flymake-jev-tests--paragraph))
    (let* ((flymake-jev-rules '((text-mode (loud "Is it loud?"))))
           (jev-max-retries 0)
           (flymake-jev-tests--results
            (list (list :status 429 :headers nil :body "{\"message\":\"Slow down\"}"))))
      (let ((reports (flymake-jev-tests--run)))
        (should-not (seq-find (lambda (report) (eq (car report) :panic)) reports)))
      (should (zerop (hash-table-count (flymake-jev--cache))))
      ;; Nothing was cached, so the next run asks again -- and this
      ;; time it is answered.
      (should (= (length (flymake-jev-tests--texts (flymake-jev-tests--run))) 1))
      (should (= (length flymake-jev-tests--requests) 2)))))


;;;; Judging and calibrating

(ert-deftest flymake-jev-test-a-judgement-is-recorded-without-the-text ()
  (let ((flymake-jev-labels-file (make-temp-file "flymake-jev-labels")))
    (unwind-protect
        (progn
          (flymake-jev--record 'hedge 0.83 'dismiss)
          (flymake-jev--record 'hedge 0.91 'confirm)
          (let ((labels (flymake-jev--labels)))
            (should (= (length labels) 2))
            (should (equal (seq-take (car labels) 3) '(hedge 0.83 dismiss)))
            (should (equal (seq-take (cadr labels) 3) '(hedge 0.91 confirm))))
          (with-temp-buffer
            (insert-file-contents flymake-jev-labels-file)
            (should-not (string-match-p "paragraph" (buffer-string)))))
      (delete-file flymake-jev-labels-file))))

(ert-deftest flymake-jev-test-a-threshold-is-fitted-to-the-judgements ()
  (let ((flymake-jev-target-precision 0.9)
        (labels nil))
    ;; Wrong below 0.8, right at and above it.
    (dolist (probability '(0.70 0.72 0.75 0.79))
      (push (list 'hedge probability 'dismiss nil) labels))
    (dolist (probability '(0.80 0.85 0.88 0.90 0.95 0.99))
      (push (list 'hedge probability 'confirm nil) labels))
    (should (equal (flymake-jev--fit labels) 0.80))
    ;; A rule that is wrong everywhere cannot be saved by a threshold.
    (should-not (flymake-jev--fit (mapcar (lambda (entry)
                                            (list (car entry) (cadr entry) 'dismiss nil))
                                          labels)))))

(ert-deftest flymake-jev-test-calibration-leaves-a-thin-record-alone ()
  (let ((flymake-jev-labels-file (make-temp-file "flymake-jev-labels"))
        (flymake-jev-min-labels 10)
        (flymake-jev-calibrated-thresholds nil)
        (saved nil))
    (unwind-protect
        (cl-letf (((symbol-function 'customize-save-variable)
                   (lambda (&rest args) (setq saved args))))
          (dolist (probability '(0.8 0.9 0.95))
            (flymake-jev--record 'hedge probability 'confirm))
          (flymake-jev-calibrate)
          (should-not saved)
          (should-not flymake-jev-calibrated-thresholds))
      (delete-file flymake-jev-labels-file))))

(ert-deftest flymake-jev-test-a-dismissed-diagnostic-stops-being-shown ()
  (flymake-jev-tests--with-buffer
      (progn (text-mode) (insert flymake-jev-tests--paragraph))
    (let* ((flymake-jev-rules '((text-mode (loud "Is it loud?"))))
           (flymake-jev-labels-file (make-temp-file "flymake-jev-labels"))
           (reports (flymake-jev-tests--run))
           (diagnostic (car (apply #'append (mapcar #'car (cdr reports))))))
      (unwind-protect
          (cl-letf (((symbol-function 'flymake-jev--diagnostic-at-point)
                     (lambda () diagnostic)))
            (flymake-jev-dismiss)
            (should (equal (seq-take (car (flymake-jev--labels)) 3) '(loud 0.9 dismiss)))
            ;; Still cached -- the answer was not wrong about what it
            ;; was asked -- but no longer shown, and not asked again.
            (should (= (hash-table-count (flymake-jev--cache)) 1))
            (should-not (flymake-jev-tests--texts (flymake-jev-tests--run)))
            (should (= (length flymake-jev-tests--requests) 1)))
        (delete-file flymake-jev-labels-file)))))

(ert-deftest flymake-jev-test-the-language-is-named-without-a-mode-line ()
  "`mode-name\=' formats to nothing where no mode line exists."
  (with-temp-buffer
    (emacs-lisp-mode)
    (should (equal (flymake-jev--language) "emacs-lisp")))
  (with-temp-buffer
    (prog-mode)
    (setq mode-name "Python")
    (should (equal (flymake-jev--language) "Python")))
  (with-temp-buffer
    (text-mode)
    (should (equal (flymake-jev--language) "text"))))

(provide 'flymake-jev-tests)
;;; flymake-jev-tests.el ends here
