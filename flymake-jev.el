;;; flymake-jev.el --- Diagnostics from rules you wrote in your own words -*- lexical-binding: t; -*-

;; Copyright (C) 2026 wakamenod

;; Author: wakamenod <wakamenod@gmail.com>
;; URL: https://github.com/wakamenod/flymake-jev.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1") (jev "0.1.0"))
;; Keywords: tools, convenience, wp
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A linter checks what a parser can see.  This one checks what you
;; meant: rules written as plain questions -- "does this paragraph
;; hedge instead of stating a claim?" -- asked of every paragraph or
;; defun in the buffer, and shown as ordinary Flymake diagnostics.
;;
;;   (setq flymake-jev-rules
;;         '((text-mode
;;            (hedge  "Does this paragraph hedge instead of stating a claim?")
;;            (jargon "Would a newcomer need a term in this paragraph defined?"
;;                    :severity :note))
;;           (git-commit-mode
;;            (imperative "Is the subject line written in the imperative mood?"
;;                        :severity :error))))
;;
;;   (add-hook 'text-mode-hook #'flymake-jev-setup)
;;   (add-hook 'prog-mode-hook #'flymake-jev-setup)
;;
;; Each unit of text is sent once, with every rule for the mode asked
;; in the same round trip.  Jev answers each one with a probability,
;; and a probability at or above the rule's threshold becomes a
;; diagnostic -- so `M-x flymake-show-buffer-diagnostics', `M-g M-n',
;; the mode line and eldoc all work as they always do.
;;
;; The probabilities are calibrated, which is what makes this
;; survivable: `flymake-jev-dismiss' records a diagnostic you did not
;; want, and `flymake-jev-calibrate' fits each rule's threshold to
;; what you have dismissed and confirmed.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'flymake)
(require 'jev)

(defgroup flymake-jev nil
  "Flymake diagnostics from rules written in prose."
  :group 'flymake
  :prefix "flymake-jev-")


;;;; Configuration

(defcustom flymake-jev-rules nil
  "Rules to check, as a list of (MODE RULE...) entries.

MODE is a major mode symbol, matched with `derived-mode-p', or
the name of a minor mode variable, matched when that variable is
bound and non-nil.  Every matching entry contributes: an
`org-mode' buffer is checked against the `text-mode' rules and
the `org-mode' ones alike.

RULE is (ID INSTRUCTIONS &key severity threshold criteria message).
ID names the rule in the diagnostic and in the calibration
record.  INSTRUCTIONS is the question, written so that yes means
there is a problem, because a probability at or above the
threshold is what becomes a diagnostic.  SEVERITY is `:error',
`:warning' (the default) or `:note'.  THRESHOLD overrides
`flymake-jev-threshold' for this rule alone.  CRITERIA is passed
to `jev-noul' to describe what true and false mean.  MESSAGE is
shown in place of INSTRUCTIONS.

When two entries define the same ID, the one written later wins."
  :type '(repeat (cons symbol (repeat sexp))))

(defvar-local flymake-jev-extra-rules nil
  "Rules added to `flymake-jev-rules' in this buffer.

Meant for `.dir-locals.el': a project describes what it cares
about without replacing what you check everywhere.  Same shape,
and the same last-one-wins rule for a repeated ID -- these are
read after `flymake-jev-rules', so a project may override a
global rule by reusing its ID.")

(defcustom flymake-jev-threshold 0.7
  "Probability at or above which a rule becomes a diagnostic.
Used for rules that do not carry their own `:threshold'."
  :type 'number)

(defcustom flymake-jev-trigger 'save
  "When the backend is allowed to ask about units it has not seen.

Flymake runs a backend both when editing stops and when the
buffer is saved, without saying which happened.  With `save', the
default, the backend asks only when the buffer has no unsaved
changes, which in practice means just after a save; a modified
buffer is still reported on, from what is already cached, so
diagnostics never go stale silently.  With `change' it asks every
time it runs.

`flymake-jev-check-buffer' ignores this."
  :type '(choice (const :tag "After saving" save)
                 (const :tag "Whenever Flymake runs" change)))

(defcustom flymake-jev-min-chars 40
  "Units shorter than this many characters are not checked.
A heading, a one-line stub or a closing brace says too little to
judge, and asking about it spends a round trip to learn nothing."
  :type 'integer)

(defcustom flymake-jev-max-in-flight 4
  "How many requests this buffer may have outstanding at once."
  :type 'integer)

(defcustom flymake-jev-max-units 200
  "How many units of one buffer are checked in a single run.
Units past this many are left for a later run; the buffer is
checked from the top, so the excess is always at the end."
  :type 'integer)

(defcustom flymake-jev-unit-functions
  '((prog-mode . flymake-jev-defun-units)
    (text-mode . flymake-jev-text-units))
  "How a buffer is cut into units, as an alist of (MODE . FUNCTION).

The first MODE that `derived-mode-p' matches decides.  FUNCTION
takes no arguments, scans the whole buffer and returns a list of
\(BEG . END) regions in buffer order.  Blank units and units
below `flymake-jev-min-chars' are dropped afterwards, so a scan
need not be careful about them."
  :type '(alist :key-type symbol :value-type function))

(defcustom flymake-jev-calibrated-thresholds nil
  "Thresholds fitted by `flymake-jev-calibrate', as an (ID . THRESHOLD) alist.

These win over a rule's own `:threshold' and over
`flymake-jev-threshold': a threshold measured against diagnostics
you have judged knows something the rule as written does not."
  :type '(alist :key-type symbol :value-type number))

(defcustom flymake-jev-labels-file
  (locate-user-emacs-file "flymake-jev-labels.el")
  "File where `flymake-jev-dismiss' and `flymake-jev-confirm' record judgements.

Each line is (ID PROBABILITY LABEL TIMESTAMP).  The text that was
judged is never written here: calibration needs the probability
and the verdict, and nothing else."
  :type 'file)

(defcustom flymake-jev-target-precision 0.9
  "Share of diagnostics at or above a fitted threshold that must be right.
`flymake-jev-calibrate' picks, for each rule, the lowest observed
probability whose diagnostics reach this precision."
  :type 'number)

(defcustom flymake-jev-min-labels 10
  "How many judgements a rule needs before its threshold is fitted.
Below this, the record says more about the last few paragraphs
than about the rule."
  :type 'integer)


;;;; Safe file-local rules

(defconst flymake-jev--rule-keywords '(:severity :threshold :criteria :message)
  "Keywords a rule may carry.")

(defun flymake-jev--atom-p (value)
  "Return non-nil when VALUE is a string, a symbol or a number."
  (or (stringp value) (symbolp value) (numberp value)))

(defun flymake-jev--safe-criteria-p (criteria)
  "Return non-nil when CRITERIA is a list of labels or labelled descriptions.
The only rule argument that is a list at all, and it is read as
data by `jev-noul'.  Its shape is still checked here, so that
what a file-local may write is a rubric and not an arbitrary
list that merely reaches Lisp looking like one."
  (and (listp criteria)
       (cl-every (lambda (entry)
                   (if (consp entry)
                       (and (flymake-jev--atom-p (car entry))
                            (let ((description (cdr entry)))
                              (or (flymake-jev--atom-p description)
                                  (and (consp description)
                                       (stringp (car description))
                                       (null (cdr description))))))
                     (flymake-jev--atom-p entry)))
                 criteria)))

(defun flymake-jev--safe-value-p (keyword value)
  "Return non-nil when VALUE may be KEYWORD\='s argument in a file-local rule."
  (if (eq keyword :criteria)
      (flymake-jev--safe-criteria-p value)
    (flymake-jev--atom-p value)))

(defun flymake-jev--safe-rule-p (rule)
  "Return non-nil when RULE is a well-formed rule holding only safe values."
  (pcase rule
    (`(,(and id (pred symbolp)) ,(pred stringp) . ,plist)
     (and id
          (cl-evenp (length plist))
          (cl-loop for (key value) on plist by #'cddr
                   always (and (memq key flymake-jev--rule-keywords)
                               (flymake-jev--safe-value-p key value)))))))

(defun flymake-jev-rules-p (value)
  "Return non-nil when VALUE is a rule list safe to take from a file.

Nothing here is evaluated or called: a rule is symbols, strings
and numbers, which is all a question ever needs.  That is what
makes `flymake-jev-rules' and `flymake-jev-extra-rules' safe to
set from `.dir-locals.el'."
  (and (listp value)
       (cl-every (lambda (entry)
                   (pcase entry
                     (`(,(and mode (pred symbolp)) . ,rules)
                      (and mode (listp rules)
                           (cl-every #'flymake-jev--safe-rule-p rules)))))
                 value)))

;;;###autoload
(progn
  (put 'flymake-jev-rules 'safe-local-variable #'flymake-jev-rules-p)
  (put 'flymake-jev-extra-rules 'safe-local-variable #'flymake-jev-rules-p))


;;;; Rules in force

(defun flymake-jev--mode-match-p (mode)
  "Return non-nil when this buffer is covered by MODE.
MODE is either a major mode this buffer derives from, or a minor
mode variable that is on -- magit writes commit messages in
`text-mode' with `git-commit-mode' switched on, and a rule about
commit messages belongs to the minor mode."
  (or (derived-mode-p mode)
      (and (boundp mode) (symbol-value mode) t)))

(defun flymake-jev--rules ()
  "Return the rules in force in this buffer, in the order they were written.
A repeated ID keeps the later rule, in the later position: the
questions sent to Jev are keyed by ID, so two rules under one
name would be one question either way."
  (let (out)
    (dolist (entry (append flymake-jev-rules flymake-jev-extra-rules))
      (when (and (consp entry) (flymake-jev--mode-match-p (car entry)))
        (dolist (rule (cdr entry))
          (setq out (cons rule (assq-delete-all (car rule) out))))))
    (nreverse out)))

(defun flymake-jev--rule-id (rule) "Return the ID of RULE." (car rule))
(defun flymake-jev--rule-instructions (rule) "Return the question RULE asks." (cadr rule))
(defun flymake-jev--rule-get (rule keyword)
  "Return RULE's KEYWORD argument, or nil."
  (plist-get (cddr rule) keyword))

(defun flymake-jev--rule-threshold (rule)
  "Return the probability at which RULE becomes a diagnostic.
A fitted threshold beats the one written into the rule, which
beats the global default."
  (or (alist-get (flymake-jev--rule-id rule) flymake-jev-calibrated-thresholds)
      (flymake-jev--rule-get rule :threshold)
      flymake-jev-threshold))

(defun flymake-jev--rule-severity (rule)
  "Return the Flymake diagnostic type RULE reports as."
  (or (flymake-jev--rule-get rule :severity) :warning))

(defun flymake-jev--rule-text (rule)
  "Return what RULE says in a diagnostic."
  (or (flymake-jev--rule-get rule :message)
      (flymake-jev--rule-instructions rule)))

(defun flymake-jev--questions (rules)
  "Return (QUESTIONS . nil) for RULES, or (nil . EXPLANATION) if one is broken.

A malformed question is the rule author's mistake, not a failure
of the run, and the explanation names the rule so that it can be
found without reading every one of them."
  (let (questions explanation)
    (cl-block nil
      (dolist (rule rules)
        (condition-case err
            (push (cons (flymake-jev--rule-id rule)
                        (jev-noul (flymake-jev--rule-instructions rule)
                                  (flymake-jev--rule-get rule :criteria)))
                  questions)
          (jev-invalid-question
           (setq explanation (format "Rule `%s' is not a question Jev can answer: %s"
                                     (flymake-jev--rule-id rule)
                                     (jev-error-message err)))
           (cl-return)))))
    (if explanation (cons nil explanation) (cons (nreverse questions) nil))))


;;;; Units

(defun flymake-jev--trim-region (beg end)
  "Return (BEG . END) with whitespace at either end left out, or nil.
Nil when nothing but whitespace is between them."
  (save-excursion
    (goto-char beg)
    (skip-chars-forward " \t\n\f" end)
    (let ((start (point)))
      (goto-char end)
      (skip-chars-backward " \t\n\f" start)
      (and (< start (point)) (cons start (point))))))

(defun flymake-jev-text-units ()
  "Return the paragraphs of this buffer as (BEG . END) regions.
In a commit message buffer the message is one unit instead: its
subject and body answer for each other, and the paragraphs of a
commit message are not what a rule about one is asking about."
  (if (bound-and-true-p git-commit-mode)
      (flymake-jev-commit-units)
    (let (units)
      (save-excursion
        (goto-char (point-min))
        (while (< (point) (point-max))
          (let ((beg (point)))
            (forward-paragraph)
            ;; `forward-paragraph' at the end of the last paragraph of
            ;; a buffer that does not end in a blank line stays put.
            (when (<= (point) beg) (goto-char (point-max)))
            (let ((unit (flymake-jev--trim-region beg (point))))
              (when unit (push unit units))))))
      (nreverse units))))

(defun flymake-jev-defun-units ()
  "Return the defuns of this buffer as (BEG . END) regions."
  (let (units)
    (save-excursion
      (goto-char (point-min))
      (while (< (point) (point-max))
        (let ((from (point)))
          (end-of-defun)
          (when (<= (point) from) (goto-char (point-max)))
          (let ((end (point))
                (beg (save-excursion (beginning-of-defun) (point))))
            ;; Between two defuns there is text belonging to neither,
            ;; and `beginning-of-defun' may walk back into the defun
            ;; already taken; keep only what moves forward.
            (when (and (< beg end) (>= beg from))
              (let ((unit (flymake-jev--trim-region beg end)))
                (when unit (push unit units))))))))
    (nreverse units)))

(defun flymake-jev-commit-units ()
  "Return the message of a commit buffer as a single (BEG . END) region.

Everything from the first comment line on is git's own scaffolding,
which git strips before the message is stored and which nobody
wrote."
  (let ((end (save-excursion
               (goto-char (point-min))
               (if (and comment-start
                        (re-search-forward
                         (concat "^" (regexp-quote (string-trim comment-start))) nil t))
                   (line-beginning-position)
                 (point-max)))))
    (let ((unit (flymake-jev--trim-region (point-min) end)))
      (and unit (list unit)))))

(defun flymake-jev--unit-function ()
  "Return the function that cuts this buffer into units, or nil."
  (cdr (seq-find (lambda (cell) (derived-mode-p (car cell)))
                 flymake-jev-unit-functions)))

(defun flymake-jev--unit-text (unit)
  "Return the text of UNIT."
  (buffer-substring-no-properties (car unit) (cdr unit)))

(defun flymake-jev--units ()
  "Return the units of this buffer worth asking about."
  (let* ((scan (flymake-jev--unit-function))
         (units (and scan (funcall scan)))
         (kept (seq-filter (lambda (unit)
                             (>= (length (string-trim (flymake-jev--unit-text unit)))
                                 flymake-jev-min-chars))
                           units)))
    (if (> (length kept) flymake-jev-max-units)
        (progn
          (flymake-log :warning "flymake-jev: %d units, checking the first %d"
                       (length kept) flymake-jev-max-units)
          (seq-take kept flymake-jev-max-units))
      kept)))

(defun flymake-jev--kind ()
  "Return the word for what one unit of this buffer is."
  (cond ((bound-and-true-p git-commit-mode) "commit message")
        ((derived-mode-p 'prog-mode) "function")
        (t "paragraph")))

(defun flymake-jev--language ()
  "Return what this buffer is written in, for the model to read.
Prose is prose whatever mode is showing it; code is not.

`mode-name' is a mode-line construct, not a name: it may hold
`:eval' forms belonging to the mode, and it formats to nothing
at all where there is no mode line to format it into.  It is
used when it is plainly a string, and the mode names itself
otherwise."
  (cond ((not (derived-mode-p 'prog-mode)) "text")
        ((and (stringp mode-name) (not (string-empty-p mode-name)))
         (substring-no-properties mode-name))
        (t (thread-last (symbol-name major-mode)
                        (string-remove-suffix "-mode")
                        (string-remove-suffix "-ts")))))

(defun flymake-jev--state (text)
  "Return the state describing TEXT.
The unit and nothing else: no file name, no path, no surrounding
buffer.  A rule is asked about what it can see."
  (list (cons 'kind (flymake-jev--kind))
        (cons 'language (flymake-jev--language))
        (cons 'text text)))


;;;; Cache and buffer state

(defvar-local flymake-jev--cache nil
  "Probabilities already known, keyed by ruleset and text.
Values are (ID . PROBABILITY) alists, kept raw: a threshold that
changes must not cost a round trip, and calibration re-reports
from here without asking anything again.")

(defvar-local flymake-jev--requests nil
  "Requests this buffer has in flight.")

(defvar-local flymake-jev--queue nil
  "Units waiting for a request slot, as (BEG END TEXT HASH).")

(defvar-local flymake-jev--report-fn nil
  "The report function of the most recent run.
Flymake hands a backend a fresh one each time and discards
reports made through an older one, so an answer that lands
between runs has to be reported through this.")

(defvar-local flymake-jev--scan nil
  "What the current run is asking, as (RULESET-KEY RULES QUESTIONS).")

(defvar-local flymake-jev--dismissed nil
  "Diagnostics judged wrong here, as (HASH . ID) pairs.
Kept beside the cache rather than in it: the probability was
right to record, and only the verdict on it changed.")

(defvar-local flymake-jev--data nil
  "Diagnostic data, where Flymake cannot carry it itself.")

(defun flymake-jev--cache ()
  "Return this buffer's probability cache, creating it if needed."
  (or flymake-jev--cache
      (setq flymake-jev--cache (make-hash-table :test #'equal))))

(defun flymake-jev--hash (key text)
  "Return the cache key for TEXT asked under ruleset KEY.
The ruleset is part of it, so editing a rule asks again rather
than answering from what a different question was told."
  (secure-hash 'sha1 (concat key "\0" text)))


;;;; Diagnostics

(defconst flymake-jev--diagnostic-data-p
  (let ((arity (func-arity 'flymake-make-diagnostic)))
    (and (fboundp 'flymake-diagnostic-data)
         (or (eq (cdr arity) 'many) (and (numberp (cdr arity)) (> (cdr arity) 5)))))
  "Whether this Flymake carries caller data on a diagnostic.")

(defconst flymake-jev--region-reports-p (version<= "28.1" emacs-version)
  "Whether this Flymake understands a report about one region.
Where it does not, an answer is reported by repeating every
diagnostic the buffer has, because a report without a region
replaces all of them.")

(defun flymake-jev--make-diagnostic (beg end type text data)
  "Return a diagnostic from BEG to END of TYPE saying TEXT, carrying DATA."
  (let ((diagnostic
         (if flymake-jev--diagnostic-data-p
             (flymake-make-diagnostic (current-buffer) beg end type text data)
           (flymake-make-diagnostic (current-buffer) beg end type text))))
    (unless flymake-jev--diagnostic-data-p
      (unless flymake-jev--data
        ;; Weak on its keys: a diagnostic Flymake has dropped takes
        ;; its data with it, without a buffer keeping a list of every
        ;; diagnostic it ever showed.
        (setq flymake-jev--data (make-hash-table :test #'eq :weakness 'key)))
      (puthash diagnostic data flymake-jev--data))
    diagnostic))

(defun flymake-jev-diagnostic-data (diagnostic)
  "Return the plist this package attached to DIAGNOSTIC."
  (if flymake-jev--diagnostic-data-p
      (flymake-diagnostic-data diagnostic)
    (and flymake-jev--data (gethash diagnostic flymake-jev--data))))

(defun flymake-jev--unit-diagnostics (beg end hash probabilities rules)
  "Return the diagnostics from BEG to END that PROBABILITIES trigger.
HASH identifies the unit for dismissals; RULES says what each
probability means."
  (when (< beg end)
    (delq nil
          (mapcar
           (lambda (rule)
             (let* ((id (flymake-jev--rule-id rule))
                    (probability (alist-get id probabilities)))
               (when (and (numberp probability)
                          (>= probability (flymake-jev--rule-threshold rule))
                          (not (member (cons hash id) flymake-jev--dismissed)))
                 (flymake-jev--make-diagnostic
                  beg end (flymake-jev--rule-severity rule)
                  (format "%s (%.2f): %s" id probability (flymake-jev--rule-text rule))
                  (list :rule id :probability probability :hash hash)))))
           rules))))

(defun flymake-jev--diagnostics (units key rules)
  "Return every diagnostic UNITS already have answers for.
KEY is the ruleset key the answers were cached under, RULES the
rules in force."
  (apply #'append
         (mapcar (lambda (unit)
                   (let ((hash (flymake-jev--hash key (flymake-jev--unit-text unit))))
                     (flymake-jev--unit-diagnostics
                      (car unit) (cdr unit) hash
                      (gethash hash (flymake-jev--cache)) rules)))
                 units)))


;;;; Asking

(defun flymake-jev--may-ask-p ()
  "Return non-nil when this run may send requests.
With the `save' trigger a modified buffer is one being typed
into, and asking about a half-written paragraph answers about a
paragraph that no longer exists by the time the answer lands."
  (or (eq flymake-jev-trigger 'change)
      (not (buffer-modified-p))))

(defun flymake-jev--probabilities (reply rules)
  "Return the (ID . PROBABILITY) alist REPLY holds for RULES.
A rule the reply says nothing about is left out rather than
counted as a no: an answer that is missing is not an answer."
  (delq nil
        (mapcar (lambda (rule)
                  (let* ((id (flymake-jev--rule-id rule))
                         (value (ignore-errors (jev-value reply id))))
                    (and (numberp value) (cons id value))))
                rules)))

(defun flymake-jev--report (diagnostics beg end)
  "Report DIAGNOSTICS for the unit between BEG and END.
Where Flymake cannot be told that a report covers one region
only, every diagnostic of the buffer is repeated instead, since
the report replaces all of them."
  (when flymake-jev--report-fn
    (if flymake-jev--region-reports-p
        (funcall flymake-jev--report-fn diagnostics :region (cons beg end))
      (pcase-let ((`(,key ,rules ,_questions) flymake-jev--scan))
        (funcall flymake-jev--report-fn
                 (flymake-jev--diagnostics (flymake-jev--units) key rules))))))

(defun flymake-jev--answered (reply buffer beg end hash)
  "Take REPLY as the answer for the unit of BUFFER between BEG and END.
HASH is what the unit said when it was asked; an edit since then
makes the answer one about text that is not there any more, and
the next run asks again."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((from (marker-position beg))
            (to (marker-position end)))
        (set-marker beg nil)
        (set-marker end nil)
        (pcase-let ((`(,key ,rules ,_questions) flymake-jev--scan))
          (when (and from to (< from to)
                     (equal hash (flymake-jev--hash
                                  key (buffer-substring-no-properties from to))))
            (let ((probabilities (flymake-jev--probabilities reply rules)))
              (puthash hash probabilities (flymake-jev--cache))
              (flymake-jev--report
               (flymake-jev--unit-diagnostics from to hash probabilities rules)
               from to))))))))

(defconst flymake-jev--fatal-errors
  '(jev-auth-error jev-configuration-error jev-billing-error jev-validation-error)
  "Errors that the next request would meet again.")

(defun flymake-jev--panic (explanation)
  "Tell Flymake to stop this backend here, saying EXPLANATION."
  (flymake-jev--abandon)
  (when flymake-jev--report-fn
    (funcall flymake-jev--report-fn :panic :explanation explanation)))

(defun flymake-jev--failed (err buffer)
  "Deal with ERR, which answered a request made from BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (if (memq (car err) flymake-jev--fatal-errors)
          (flymake-jev--panic (format "Jev: %s" (jev-error-message err)))
        ;; jev.el has already retried what is worth retrying, so this
        ;; is the network or the provider being busy.  Nothing is
        ;; cached, which is all it takes for the next run to ask again.
        (flymake-log :warning "flymake-jev: %s" (jev-error-message err))
        (flymake-jev--pump)))))

(defun flymake-jev--settled (buffer request)
  "Note that REQUEST of BUFFER is over, whichever way it ended."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq flymake-jev--requests (delq request flymake-jev--requests)))))

(defun flymake-jev--ask (unit)
  "Send the request for UNIT, which is (BEG END TEXT HASH)."
  (pcase-let* ((`(,beg ,end ,text ,hash) unit)
               (buffer (current-buffer))
               (beg-marker (copy-marker beg))
               (end-marker (copy-marker end t))
               (questions (nth 2 flymake-jev--scan))
               (request nil))
    (setq request
          (jev-ask (flymake-jev--state text) questions
                   :success
                   (lambda (reply _tag)
                     (flymake-jev--settled buffer request)
                     (flymake-jev--answered reply buffer beg-marker end-marker hash)
                     (when (buffer-live-p buffer)
                       (with-current-buffer buffer (flymake-jev--pump))))
                   :error
                   (lambda (err _tag)
                     (set-marker beg-marker nil)
                     (set-marker end-marker nil)
                     (flymake-jev--settled buffer request)
                     (flymake-jev--failed err buffer))))
    (push request flymake-jev--requests)))

(defun flymake-jev--pump ()
  "Send as many queued requests as this buffer is allowed to have in flight."
  (while (and flymake-jev--queue
              (< (length flymake-jev--requests) flymake-jev-max-in-flight))
    (flymake-jev--ask (pop flymake-jev--queue))))

(defvar flymake-jev--force nil
  "Non-nil while a run must ask whatever `flymake-jev-trigger' says.")

;;;###autoload
(defun flymake-jev (report-fn &rest _args)
  "Flymake backend asking `flymake-jev-rules' about this buffer.
REPORT-FN is called as Flymake's calling convention requires --
always at least once, from what is already known, so that a run
that asks nothing still leaves Flymake with an answer."
  (setq flymake-jev--report-fn report-fn)
  (let ((rules (flymake-jev--rules)))
    (if (null rules)
        (funcall report-fn nil)
      (pcase-let ((`(,questions . ,explanation) (flymake-jev--questions rules)))
        (if explanation
            (flymake-jev--panic explanation)
          (let* ((key (prin1-to-string rules))
                 (units (flymake-jev--units)))
            (setq flymake-jev--scan (list key rules questions))
            ;; Everything known, in one report: a unit that has been
            ;; edited is no longer in the cache, and its diagnostic
            ;; disappears here rather than hanging over new text.
            (funcall report-fn (flymake-jev--diagnostics units key rules))
            ;; A queued unit may have been edited since it was queued,
            ;; so the queue is rebuilt; requests already in flight are
            ;; left alone, because an answer is checked against the
            ;; text it was asked about before it is believed.
            (setq flymake-jev--queue nil)
            (when (or flymake-jev--force (flymake-jev--may-ask-p))
              (dolist (unit units)
                (let* ((text (flymake-jev--unit-text unit))
                       (hash (flymake-jev--hash key text)))
                  (unless (gethash hash (flymake-jev--cache))
                    (push (list (car unit) (cdr unit) text hash) flymake-jev--queue))))
              (setq flymake-jev--queue (nreverse flymake-jev--queue))
              (flymake-jev--pump))))))))


;;;; Setting up and tidying away

(defun flymake-jev--abandon ()
  "Drop everything this buffer has outstanding."
  (mapc #'jev-cancel flymake-jev--requests)
  (setq flymake-jev--requests nil)
  (setq flymake-jev--queue nil))

(defun flymake-jev--maybe-abandon ()
  "Drop outstanding requests when Flymake has been turned off here.
Nobody is going to be shown the answers, and they still cost."
  (unless (bound-and-true-p flymake-mode)
    (flymake-jev--abandon)))

;;;###autoload
(defun flymake-jev-setup ()
  "Add `flymake-jev' to the Flymake backends of this buffer.
Meant for a mode hook.  This does not turn `flymake-mode' on:
whether Flymake runs at all is your decision, not a rule's."
  (interactive)
  (add-hook 'flymake-diagnostic-functions #'flymake-jev nil t)
  (add-hook 'kill-buffer-hook #'flymake-jev--abandon nil t)
  (add-hook 'flymake-mode-hook #'flymake-jev--maybe-abandon nil t))

;;;###autoload
(defun flymake-jev-check-buffer ()
  "Ask about every unit of this buffer that has no answer yet.
Unlike an ordinary run, this ignores `flymake-jev-trigger'."
  (interactive)
  (unless (bound-and-true-p flymake-mode)
    (user-error "Flymake is not on in this buffer"))
  (let ((flymake-jev--force t))
    (flymake-start t)))

;;;###autoload
(defun flymake-jev-clear-cache ()
  "Forget every answer this buffer has, and ask again."
  (interactive)
  (setq flymake-jev--cache nil)
  (setq flymake-jev--dismissed nil)
  (when (bound-and-true-p flymake-mode)
    (let ((flymake-jev--force t))
      (flymake-start t))))


;;;; Judging diagnostics

(defun flymake-jev--diagnostics-at-point ()
  "Return this backend's diagnostics under point, innermost first."
  (seq-filter (lambda (diagnostic)
                (and (eq (flymake-diagnostic-backend diagnostic) 'flymake-jev)
                     (flymake-jev-diagnostic-data diagnostic)))
              (flymake-diagnostics (point))))

(defun flymake-jev--diagnostic-at-point ()
  "Return the diagnostic to judge at point, asking when several overlap."
  (let ((candidates (flymake-jev--diagnostics-at-point)))
    (pcase candidates
      ('nil (user-error "No flymake-jev diagnostic at point"))
      (`(,one) one)
      (_ (let* ((choices (mapcar (lambda (diagnostic)
                                   (cons (flymake-diagnostic-text diagnostic) diagnostic))
                                 candidates))
                (pick (completing-read "Which diagnostic? " choices nil t)))
           (cdr (assoc pick choices)))))))

(defun flymake-jev--record (id probability label)
  "Append the judgement LABEL of ID at PROBABILITY to `flymake-jev-labels-file'."
  (let ((entry (list id probability label (format-time-string "%FT%T%z"))))
    (with-temp-buffer
      (insert (prin1-to-string entry) "\n")
      (let ((write-region-inhibit-fsync t))
        (write-region (point-min) (point-max) flymake-jev-labels-file t 'quiet)))
    entry))

(defun flymake-jev--judge (label)
  "Record the diagnostic at point as LABEL."
  (let* ((diagnostic (flymake-jev--diagnostic-at-point))
         (data (flymake-jev-diagnostic-data diagnostic))
         (id (plist-get data :rule))
         (probability (plist-get data :probability)))
    (flymake-jev--record id probability label)
    (when (eq label 'dismiss)
      (push (cons (plist-get data :hash) id) flymake-jev--dismissed)
      ;; The answer stays cached -- it was not wrong about what it was
      ;; asked -- so this only stops it from being shown again.
      (when (bound-and-true-p flymake-mode) (flymake-start t)))
    (message "flymake-jev: %s recorded as %s (%.2f)" id label probability)))

;;;###autoload
(defun flymake-jev-dismiss ()
  "Record the diagnostic at point as one you did not want, and hide it."
  (interactive)
  (flymake-jev--judge 'dismiss))

;;;###autoload
(defun flymake-jev-confirm ()
  "Record the diagnostic at point as one that was right."
  (interactive)
  (flymake-jev--judge 'confirm))

(defun flymake-jev--labels ()
  "Return the recorded judgements, as (ID PROBABILITY LABEL TIMESTAMP) entries."
  (when (file-readable-p flymake-jev-labels-file)
    (with-temp-buffer
      (insert-file-contents flymake-jev-labels-file)
      (goto-char (point-min))
      (let (entries)
        (condition-case nil
            (while t (push (read (current-buffer)) entries))
          ;; A half-written last line is the file being appended to,
          ;; not a reason to throw away everything before it.
          (error nil))
        (nreverse entries)))))

(defun flymake-jev--fit (labels)
  "Return the lowest threshold in LABELS reaching `flymake-jev-target-precision'.
LABELS are the entries recorded for one rule.  Nil when no
observed probability is precise enough: a rule that is wrong as
often at 0.99 as at 0.5 cannot be fixed by raising its bar."
  (let ((candidates (sort (delete-dups
                           (mapcar #'cadr labels))
                          #'<)))
    (seq-find (lambda (candidate)
                (let* ((above (seq-filter (lambda (entry) (>= (cadr entry) candidate))
                                          labels))
                       (right (seq-count (lambda (entry) (eq (nth 2 entry) 'confirm))
                                         above)))
                  (and above
                       (>= (/ (float right) (length above))
                           flymake-jev-target-precision))))
              candidates)))

;;;###autoload
(defun flymake-jev-calibrate ()
  "Fit each rule's threshold to the diagnostics you have judged.

A rule with fewer than `flymake-jev-min-labels' judgements is
left alone.  Nothing is asked again: the cached probabilities are
what a threshold is applied to, so every buffer re-reports from
what it already has."
  (interactive)
  (let ((by-rule (make-hash-table :test #'eq))
        (fitted (copy-sequence flymake-jev-calibrated-thresholds))
        (report nil))
    (dolist (entry (flymake-jev--labels))
      (when (and (symbolp (car entry)) (numberp (cadr entry)))
        (push entry (gethash (car entry) by-rule))))
    (maphash
     (lambda (id labels)
       (when (>= (length labels) flymake-jev-min-labels)
         (let ((threshold (flymake-jev--fit labels))
               (before (or (alist-get id flymake-jev-calibrated-thresholds)
                           flymake-jev-threshold)))
           (when (and threshold (/= threshold before))
             (setf (alist-get id fitted) threshold)
             (push (format "%s: %.2f -> %.2f (n=%d)" id before threshold (length labels))
                   report)))))
     by-rule)
    (if (null report)
        (message "flymake-jev: nothing to calibrate yet")
      (customize-save-variable 'flymake-jev-calibrated-thresholds fitted)
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and (bound-and-true-p flymake-mode)
                     (memq #'flymake-jev flymake-diagnostic-functions))
            (flymake-start t))))
      (message "flymake-jev: %s" (string-join (nreverse report) ", ")))))

(provide 'flymake-jev)
;;; flymake-jev.el ends here
