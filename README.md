# flymake-jev.el

Flymake diagnostics from rules you wrote in your own words.

A linter checks what a parser can see. This checks what you meant:

```elisp
(setq flymake-jev-rules
      '((text-mode
         (hedge  "Does this paragraph hedge instead of stating a claim?")
         (jargon "Would a newcomer need a term in this paragraph defined?"
                 :severity :note))
        (git-commit-mode
         (imperative "Is the subject line written in the imperative mood?"
                     :severity :error)
         (why        "Does the body explain why the change was made, not only what changed?"))
        (prog-mode
         (doc-match "Does the docstring or leading comment describe what this code actually does?")
         (magic     "Is there a numeric or string literal here whose meaning is not explained?"
                    :severity :note))))

(add-hook 'text-mode-hook #'flymake-jev-setup)
(add-hook 'prog-mode-hook #'flymake-jev-setup)
```

Every paragraph of prose, and every defun of code, is checked against the rules
for its mode:

```
hedge (0.83): Does this paragraph hedge instead of stating a claim?
imperative (0.91): Is the subject line written in the imperative mood?
```

These are ordinary Flymake diagnostics, so `M-x flymake-show-buffer-diagnostics`,
`M-g M-n`, the mode line and eldoc all work the way they already do.

## How it works

Each unit — a paragraph, a defun, a commit message — is sent once to
[Jev](https://github.com/wakamenod/jev.el), TypeSafe AI's typed-decision model,
with *every* rule for the mode asked in the same round trip. Each rule comes
back as a probability, and a probability at or above the rule's threshold
becomes a diagnostic. A paragraph takes about 200ms and costs input tokens only.

Jev decides; it does not write. There is no generation here, no rewriting, no
suggested fix. The worst a bad answer can do is underline a paragraph that was
fine.

## Install

Emacs 27.1, [jev.el](https://github.com/wakamenod/jev.el), and an API key jev.el
can find (its README covers the macOS Keychain and `~/.authinfo.gpg`).

```elisp
(require 'flymake-jev)
(add-hook 'text-mode-hook #'flymake-jev-setup)
```

`flymake-jev-setup` adds the backend to the buffer. It does *not* turn on
`flymake-mode`: whether Flymake runs at all stays your decision.

## Rules

```elisp
(MODE RULE...)
RULE = (ID INSTRUCTIONS &key severity threshold criteria message)
```

`MODE` is a major mode, matched with `derived-mode-p`, or a minor mode variable,
matched when it is on. Every matching entry contributes, so an `org-mode` buffer
is checked against the `text-mode` rules *and* the `org-mode` ones; when two
entries use the same `ID`, the later one wins. The minor mode case is what makes
commit messages work: magit writes them in `text-mode` with `git-commit-mode`
switched on.

Write the question so that **yes means there is a problem**. Only one direction
is checked — the probability that the answer is yes, against the threshold.

| | |
|---|---|
| `:severity` | `:error`, `:warning` (default) or `:note` |
| `:threshold` | Overrides `flymake-jev-threshold` for this rule |
| `:criteria` | Passed to `jev-noul` to describe what true and false mean |
| `:message` | Shown in place of the question |

Rules are data — symbols, strings and numbers, nothing that runs — so they are
safe to set per project from `.dir-locals.el`:

```elisp
((nil . ((flymake-jev-extra-rules
          . ((prog-mode
              (error-wrapped "Is an error returned without saying what failed?")))))))
```

`flymake-jev-extra-rules` adds to `flymake-jev-rules` rather than replacing it.

## Commands

| | |
|---|---|
| `flymake-jev-setup` | Add the backend to this buffer. For a mode hook |
| `flymake-jev-check-buffer` | Ask about every unit with no answer yet, whatever `flymake-jev-trigger` says |
| `flymake-jev-clear-cache` | Forget this buffer's answers and ask again |
| `flymake-jev-dismiss` | Record the diagnostic at point as one you did not want, and hide it |
| `flymake-jev-confirm` | Record the diagnostic at point as right |
| `flymake-jev-calibrate` | Fit each rule's threshold to what you have judged |

## Calibration

This is the part a linter cannot do. A rule that is wrong one time in three gets
turned off, however good it is the other two times — and no amount of rewording
tells you where its bar should be. Jev's probabilities are calibrated, so the
bar can be measured instead:

```
M-x flymake-jev-calibrate
flymake-jev: hedge: 0.70 -> 0.84 (n=23), magic: 0.70 -> 0.76 (n=41)
```

`flymake-jev-dismiss` and `flymake-jev-confirm` append `(ID PROBABILITY LABEL
TIMESTAMP)` to `flymake-jev-labels-file` — the rule, the number and the verdict,
never the text that was judged. `flymake-jev-calibrate` reads that record and
picks, for each rule with at least `flymake-jev-min-labels` judgements, the
lowest observed probability whose diagnostics are right
`flymake-jev-target-precision` of the time. Nothing is asked again: the
probabilities are cached, so every buffer re-reports from what it already has.

A rule that is no more right at 0.99 than at 0.5 is left alone. That is a rule
to rewrite, not a threshold to raise.

## Settings

| | Default | |
|---|---|---|
| `flymake-jev-rules` | `nil` | The rules, by mode |
| `flymake-jev-extra-rules` | `nil` | Buffer-local additions, for `.dir-locals.el` |
| `flymake-jev-threshold` | `0.7` | Probability at which a rule without its own becomes a diagnostic |
| `flymake-jev-trigger` | `save` | `save` asks only when the buffer has no unsaved changes; `change` asks whenever Flymake runs. Either way a run reports what is already known |
| `flymake-jev-min-chars` | `40` | Units shorter than this are not asked about |
| `flymake-jev-max-in-flight` | `4` | Requests one buffer may have outstanding |
| `flymake-jev-max-units` | `200` | Units checked in one run; the rest wait for the next |
| `flymake-jev-unit-functions` | paragraphs, defuns | How a buffer is cut up, by mode |
| `flymake-jev-calibrated-thresholds` | `nil` | Fitted thresholds; they win over a rule's own |
| `flymake-jev-labels-file` | `~/.emacs.d/flymake-jev-labels.el` | Where judgements are recorded |
| `flymake-jev-target-precision` | `0.9` | Precision a fitted threshold must reach |
| `flymake-jev-min-labels` | `10` | Judgements a rule needs before it is fitted |

## Units

A unit is what one question is asked about, and what a diagnostic underlines.

| Mode | Unit |
|---|---|
| `prog-mode` | One defun, from `beginning-of-defun` to `end-of-defun` |
| `text-mode` | One paragraph |
| `git-commit-mode` | The whole message, minus git's own comment lines |

`org-mode` uses the `text-mode` paragraphs for now; headings and `#+` lines are
mostly dropped by `flymake-jev-min-chars`. Add your own with
`flymake-jev-unit-functions`: a function of no arguments, returning `(BEG . END)`
regions in buffer order.

## What is sent, and what it costs

One unit at a time: its text, the word for what it is (`paragraph`, `function`,
`commit message`) and the language. **No file name, no path, and nothing
around it.** A rule is asked about what it can see.

Answers are cached in memory, keyed by the text *and* the rules, so a buffer is
asked about a paragraph once — editing it asks again, editing a rule asks again,
and nothing is written to disk. The judgement record holds probabilities and
verdicts, never text.

With the default `save` trigger, a buffer costs one round trip per changed
paragraph per save, and nothing at all while you type.

## Status

v0.1. `org-mode` units, tree-sitter defuns, and asking *which sentence* caused a
diagnostic are next.

## License

GPL-3.0-or-later.
