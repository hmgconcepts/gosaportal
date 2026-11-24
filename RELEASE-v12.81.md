# School Connect — V12.81

**20 November 2026 · The prep exam opens at the time the school typed — and closes when it ends**

A rehearsal set for 10:00 could not be sat until 11:00. That was the report. It
was true, it was reproducible, and it was not one bug: it was a family of them,
all in the same hour of the same page.

---

## 1. Why 10:00 became 11:00

A `<input type="datetime-local">` gives the page a string with **no timezone**:
`2026-11-20T10:00`. What that string means depends entirely on who reads it:

| Reader | What `2026-11-20T10:00` meant |
|---|---|
| `new Date(...)` in Chrome, Edge, Firefox, modern Safari | the device's local time — correct |
| `new Date(...)` in older WebKit / some Android WebViews | **UTC** — an hour out in Lagos |
| Postgres, receiving it as text for a `timestamptz` column | the **database's** session timezone, which on Supabase is **UTC** — an hour out, every time |

The exam editor posted that string **raw**. So every save of the edit form wrote
10:00 school time into the database as *10:00 UTC* — which is 11:00 in Lagos.
The learner's dashboard showed 11:00, "Sit now" appeared at 11:00, and the exam
page refused to open the paper before 11:00. Nothing was wrong with the sitting;
the number beside it was wrong.

Worse, the same form **displayed** the stored instant in UTC: an exam set for
10:00 reopened showing **09:00**. The tutor would "correct" it back to 10:00,
which stored 11:00 again. Every edit moved the paper an hour later.

**The fix is one conversion, written once**, in `assets/js/app.js`:

```js
SC.time.toIso('2026-11-20T10:00')      // → '2026-11-20T09:00:00.000Z'  (the instant it names)
SC.time.toLocalInput('2026-11-20T09:00:00Z') // → '2026-11-20T10:00'   (exactly back)
SC.time.isNaive('2026-11-20T10:00')    // → true — the dangerous kind of string
```

`toIso` reads the digits and builds a local `Date` itself, so the answer never
depends on the browser's parser. Every page that writes a timetable instant now
uses it, in both directions — create, edit, and the live preview above the
fields, which now prints **both clocks** ("Opens … 10:00 (09:00 UTC)") so a
tutor can see exactly what will be stored.

## 2. The New Exam form was throwing the schedule away

While proving the above, the audit found something worse: the Create button runs
the *second* `CBTUI.save` in `cbt.html` (a V12.28 rewrite that overrides the
first), and that version **never sent `start_at`, `close_at` or `venue` at all**.
A prep exam created from the New Exam form with a start time arrived with no
window — it could not be scheduled, could not appear on the timetable, and fell
straight into fault 3 below.

Both builders now send the schedule, and the dead one is labelled as dead so the
next person does not "fix" the wrong copy.

## 3. A sitting with a start time and no closing time stayed open for ever

Every gate compared `now()` against `close_at`. A prep exam set for Monday
10:00 with no closing time was still sittable on Friday — and the Exam
Timetable had been telling learners it ran 10:00–10:45 the whole time.

There is now one definition of the end of a sitting, used by all of them:

```sql
sc_cbt_close(start_at, close_at, duration_min, duration) =
    coalesce(close_at, start_at + the paper's own length)
```

The public exam getter, the window state, the learner's list, the timetable row
and the "Sit now" button all read that one function, so **what the learner is
told is what the database enforces**.

## 4. A learner who began inside the window was losing the whole sitting

`cbt_submit_v5` accepted answers only until `close_at + 120 seconds`. A paper
that closed at 10:45 threw away the answers of anyone who began at 10:40, with
no way back — the sitting simply vanished.

A submission is now accepted until **the sitting's own length has elapsed past
the close** (plus two minutes): a learner who is inside the window when they
begin always gets their paper's time to finish. The *door* still closes on
time; only the answering of a paper already begun is protected.

## 5. What else the audit found

| Fault | Effect | Fix |
|---|---|---|
| Attempts were counted by `student_id_ref = full_name` | Two learners named "John Doe" shared one attempt, and could each read the other's score | Attempts match the **admission number** — the identity the CBT engine itself uses |
| `last_percent` returned regardless of `release_results` | A learner saw their score the instant they submitted, before the tutor released results | Withheld until released |
| `attempt_limit = 0` displayed as `1` | "0 of 1 attempts" on an unlimited paper | `0` reads as unlimited, as it does everywhere else |
| `duration` and `duration_min` could disagree | A paper that opened as 45 minutes and closed as 60 | A trigger keeps them one number |
| The `public_link` of a paper was returned to learners and parents | A share key handed out by a list | Staff only |
| Countdown used the device clock | A phone an hour out showed the paper opening an hour early or late | The countdown runs on the **server's** `server_now`, and the server still decides |
| `'Africa/Lagos'` hard-coded in the exam functions | A school in another zone saw every time shifted | `sc_school_tz()` reads `school_settings.school_timezone`, defaulting to Lagos |

## 6. What to do about sittings already written an hour late

Nothing is guessed and nothing is moved automatically — a shift applied to the
wrong row is worse than the original fault. **CBT → 🕒 Check prep times** lists
every sitting with the school clock, the instant actually stored, and whether it
is open now, with **−1 h / −15 m / +15 m / +1 h**. One click rewrites the exam
*and* its Exam Timetable row together.

---

## What was proved

Two new suites, both wired into the release gate.

**`tools/verification/t55-prep-window-db.mjs` — 27 passed, 0 failed.** It loads
the shipped schema into Postgres (PGlite) and proves: a 10:00/45-minute paper
ends 10:45 school time; a tutor's closing time wins; a sitting whose length has
passed is `expired` (it used to say `open` for ever); the public getter refuses
it; a learner who began inside the window can submit a minute after it closes
and the answer is **marked**; three hours late is refused; two learners with the
same name keep separate attempt counts; an unreleased score is `null`; `0`
attempts reads unlimited; `duration`/`duration_min` move together; the timetable
row says 10:00–10:45 and then 12:30 when a closing time is set; the learner
reads school time, not UTC; and a learner is not handed the share link.

**`tools/verification/t56-prep-time-round26.mjs` — 22 passed, 0 failed.** It
drives the real CBT page in a browser pinned to `Africa/Lagos`: 10:00 typed
becomes `09:00Z`; the Create button posts that instant; the edit form opens
showing **10:00**; saving it unchanged does not move the exam by a second;
typing 11:00 stores 11:00 school time; the live preview prints both clocks; the
learner's countdown follows the server, not a device an hour out; the repair
tool moves a wrong sitting back an hour and re-syncs its timetable row; and no
shipped page converts a `datetime-local` value the old way.

The existing suites still pass: `t52` (the sitting is sittable inside its window
and nowhere else), `t45`, `t46`, `t36`, plus the schema gates — verifier **ALL
PASS** (object-identical), upgrade audit **ALL PASS**, `t53` schema upgrade,
idempotence test, `audit-v5` **513/0**.

## Database

`database/complete-schema.sql` — V12.81, 998,538 bytes (Supabase's editor limit
is 1,000,000). One defaulted column, two functions, one trigger; six function
bodies corrected. Nothing is dropped; nothing is renamed.

## Updating

1. Back up Supabase.
2. Paste `database/complete-schema.sql` into the SQL Editor and Run. The last
   line should read `V12.81 installed — …`.
3. Upload the new files over the old ones.
4. On a phone, press **Update now** when the bar appears.
5. CBT → **🕒 Check prep times**, and correct anything that already drifted.
