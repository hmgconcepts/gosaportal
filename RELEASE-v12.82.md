# Release V12.82 — Prep sittings every tutor can read, and a portal that survives a bad line

**Round 27.** Two reports arrived a morning apart, and they turned out to be the same
evening seen from two sides:

> "Each teacher must be able to see **his own** prep exam timetable for each class — so he
> can spot a wrong time or a wrong duration — and also see the **other teachers'** prep
> timetables."

> "During **home** prep exams, logins fail, submissions fail, and students are logged out
> suddenly. In-school midterm and terminal exams never do this, and they have **more**
> students." — followed by Supabase's own email: **"Your project is running out of Disk IO
> Budget"** (project `auptmhagbksebetbxknv`, God of Seed Academy Portal).

---

## 1. The tutor's prep diary — `exam-timetable.html`

A new card, **🧑‍🏫 Prep sittings by tutor**, sits directly under the learner's prep list
and is **staff-only** (a learner or a parent never receives the data at all — the function
returns no rows for them, and the card hides itself).

* **My sittings** (default) — every prep paper assigned to the signed-in tutor.
* **All tutors** — the whole school's prep diary, grouped by tutor, in one click.
* Each row shows the **day**, the **clock in school time** (e.g. `10:00–10:45`), the
  **length the database enforces**, the **class**, the paper, the venue, the status, and
  how many learners have sat it.

**And it names the faults**, on the row that carries them, in plain words:

| Flag | Means |
|---|---|
| `closing_time_vs_length` | "closing time disagrees with the length" — *the exact fault that let a 45-minute paper run all night in V12.81* |
| `clashes_with_another_paper` | this sitting overlaps another prep paper for the same class (shown on **both** rows, across tutors) |
| `closes_before_it_opens` | the end is before the start |
| `no_start_time` / `no_duration` | a paper that will never open, or has no length |
| `under_10_minutes` / `over_3_hours` / `open_all_day` | a length nobody intended |
| `outside_school_hours` | starts before 05:00 or after 22:00 school time |
| `no_class` / `not_on_timetable` | the paper will not reach the class that needs it |

Backed by **`sc_prep_teacher_timetable(p_scope, p_class, p_tz)`** — one call, school time,
`SECURITY DEFINER`, `revoke all … from public, anon`, and a role check that returns
**nothing** to a learner or a parent.

---

## 2. Why home exams broke and school exams did not

Not the students, and not the papers. Three separate mechanisms, all triggered by a
connection that is slow, shared, or rate-limited:

1. **The request bill.** Every signed-in tab made, every 30 seconds: a **50-row
   notification select**, an **`auth.getUser()` round trip** (a real network request) and
   a **message-badge RPC**; the licence RPC ran every 15 minutes *and on every tab focus*;
   the messages page polled twice. On Nano (0.5 GB RAM) that is what spends the daily
   **Disk IO budget** — and when the budget is gone Supabase drops the instance to
   baseline disk throughput, so *everything* times out at once.
2. **The auth rate limiter.** Supabase Auth limits **per IP address**: 30 sign-ins and
   150 token refreshes per 5 minutes by default. In school, a class shares the school's
   own connection. At home on mobile data, a **carrier CGNAT** puts thousands of
   subscribers behind one address, so the school's students share that budget with the
   whole mast. Over the limit the answer is `429` — not "wrong password".
3. **The browser treated a slow second as a verdict.** A failed token refresh produced
   `SIGNED_OUT` and a redirect to the login page (the "sudden logout"); a 429 at sign-in
   was shown as "cannot sign in"; a submission that timed out ended in a dead end with a
   JSON download, with the answers left in a queue nothing would ever send.

---

## 3. What the app now does instead

**New: `assets/js/net-resilience.js`** — loaded by every page, before `config.js`.

| Behaviour | Detail |
|---|---|
| `SCNet.retry(fn)` | exponential backoff with **full jitter** on transient errors only (network, `429`, `5xx`, statement timeout). A wrong password is never retried. |
| `SCNet.session(sb)` | reads the session **locally** (`getSession`), refreshes early, and on a failed refresh **keeps the session** and reports it as *stale* — never as signed out. |
| `SCNet.user(sb)` | answers "who am I" from the session, with **no network call**; the network is asked only when there is no session. |
| `SCNet.signIn()` | retries a `429` with waits and says **"the network is busy… press Sign in again"**. |
| `SCNet.poll(name, fn, ms)` | **one scheduler** for every badge: visible tabs only, offline = silent, random jitter, minimum gap 20 s, and a sitting stretches or stops everything that is not critical. |
| `SCNet.examMode(on)` | the sitting silences the shell. |
| `SCNet.enqueue/flush` | a **durable submit queue** in `localStorage`, idempotent by key, cleared **only** after the database confirms. |

**What that did to the request bill, per learner:**

| | V12.81 | V12.82 |
|---|---|---|
| Bell | 50-row select + `/auth/user` + badge RPC, every 30 s | **one** `sc_poll_bundle` count, every 2 min, hidden tabs silent |
| Messages page | badge every 45 s + thread re-read every 30 s | 3 min / 1 min, on the shared scheduler |
| Licence | every 15 min **and every tab focus** | every 30 min, visible only |
| Sitting in progress | other pollers keep running | **zero** background traffic from the shell |
| Failed refresh | signed out | session kept, retried quietly |
| Failed submit | dead end | queued, retried, sent on reconnect |

**Schema additions** (all inside `database/complete-schema.sql`, extract in
`database/v12.82-load-and-timetable.sql`):

* `sc_poll_bundle()` — bell count + message badge + licence verdict + server clock, in one call;
* `sc_prep_teacher_timetable(scope, class, tz)` — the tutor diary above;
* `sc_io_report()` — **which table is doing the writing**: top writers, top full scans,
  bloat, connections, database size, plus plain-English advice. Admin only;
* `sc_prune_noise(days)` — bounded retention for `notifications` and `login_audit`
  (default 120 days, minimum 30). Admin only;
* two **duplicate indexes removed** from `cbt_results` (every submission was paying to
  write the same column twice) and one index added for the bell's own read.

**Surface:** **Platform Health → 🩺 Load & Disk IO** — the report renders on the page,
reads only when the section is opened (a health page that costs a scan to look at is part
of the problem), and has the prune button beside it.

---

## 4. Documents

* **`EXAM-WEEK-LOAD-PLAYBOOK.md`** (new) — the five-minute dashboard checklist (raise the
  two auth rate limits first), the exam-morning routine, what "healthy" looks like
  afterwards, and the escalation order. Written for the school's administrator, not for a
  developer.
* **`SUPABASE_FREE_TIER_PROTECTION.md`** — new *Part 2*: the Disk IO budget, the auth rate
  limits, the CGNAT explanation, and the three rules that keep the free tier healthy.

---

## 5. Verification

| Suite | Result |
|---|---|
| `tools/verification/t57-prep-timetable-and-poll-bundle.mjs` (new, Postgres) | **50 / 0** |
| `tools/verification/t58-tutor-timetable-and-resilience.mjs` (new, browser) | **47 / 0** |
| `tools/verify-complete-schema.mjs` | **ALL PASS** — object-identical, idempotent, under the 1 MB cap |
| `tools/audit-schema-upgrade.py` | ALL PASS |
| `tools/test-complete-schema-idempotence.mjs` | PASS |
| full gate (`work/run-all-tests.sh`) | **ALL SUITES PASS** |

**Schema size: 998,213 B** (cap 1,000,000; headroom **1,787 B**). Headroom had fallen to
1,462 B before this round, so the build tool gained four *provable* reclaim rules — each
one removes only what a sequential run cannot observe, and the verifier proves the
resulting catalogue is byte-identical object for object:

| Rule | What it removes | Saved |
|---|---|---|
| one row per `sc_install_state` key | a release marker re-inserted 11 times with `on conflict do nothing` | 28 statements |
| repeated `enable row level security` | the same table asserted twice | 28 statements |
| reload signals written two ways | **100** `pg_notify('pgrst','reload schema')` in one file, 99 firing before the objects they announce | 199 |
| grants already covered by a later grant | `grant … to authenticated` followed by `grant … to anon, authenticated` | 47 |

> The reload-signal rule is worth its own line: the V12.68 fix was **not working** for a
> hundred of those statements because a pack had glued `notify pgrst,'reload schema'` and
> `select pg_notify(...)` onto one line. There is now exactly **one** reload signal in the
> shipped file, and it is the last statement.

---

## 6. Upgrade

1. Run **`database/complete-schema.sql`** once in the Supabase SQL Editor (safe twice).
2. Do the **five-minute dashboard checklist** in `EXAM-WEEK-LOAD-PLAYBOOK.md` §3 —
   *raise the two auth rate limits first*.
3. Open **Platform Health → Load & Disk IO → ↻ Read the report**, and **🧹 Prune old notices**.
4. On every device, reload once so the versioned service-worker cache moves to
   `v12.82-20261121-1`.
