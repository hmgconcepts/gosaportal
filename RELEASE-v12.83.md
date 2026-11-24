# School Connect V12.83 — "the four things that were not the exam"

**Release date:** 21 November 2026 · **Database change:** none · **New dependency:** none
**Supabase plan:** unchanged (free tier) · **Files:** client-only

---

## 1. Why this round exists

Round 27 fixed what the school reported: prep exams at home, the tutor's diary, the
Disk IO budget. This round asked a different question — *what else on this platform is
quietly wrong, the kind of wrong nobody reports because it looks like something else?*

Four were found, each verified against the real pages before a line was changed, and
each now has a browser test that fails if it ever comes back.

| # | What the school would say | What was actually happening |
|---|---|---|
| 1 | "The register I marked last night was saved under yesterday." | **103 places** computed the calendar day in **UTC**, not in the school's timezone. |
| 2 | "It signs us out for no reason — mostly at home, mostly when the laptop is also open." | **Every open tab refreshed the same token.** The second one spent a refresh token the first had already rotated away. |
| 3 | "It says we are offline when we are not, and my classes are empty." | When the "who am I" call failed, the shell **invented a role — `student`** — and rendered a teacher as a learner. |
| 4 | "The page reloads itself while I am typing." / "Somebody else's dashboard opened on this phone." | A first visit **reloaded the page** on install, and a sign-out left **the previous session's pages in the offline cache**, readable by the next person with no sign-in at all. |

---

## 2. Issue 1 — a date is not an instant

### What was wrong

```js
new Date().toISOString().slice(0, 10)     // ← the UTC day
```

`toISOString()` is always UTC. Lagos is **UTC+1**, so anything recorded between
**00:00 and 00:59 local** is filed under *yesterday*: a night-duty attendance register,
a receipt typed just after midnight, a diary entry. In any country **west of
Greenwich** it is far worse — for most of the evening the UTC day is *tomorrow*.

It mattered because that string is what the platform stores and compares:
`attendance.date`, receipt dates, diary dates, "is my paper today?" filters,
`exam_timetable` windows.

The product already contained the correct idiom — exactly once, in the fee ledger
(`crud.js`: `new Date().toLocaleDateString('en-CA', { timeZone: 'Africa/Lagos' })`).
One place right, 103 places wrong.

### What changed

One helper, in `assets/js/net-resilience.js` (already on every page, before `config.js`):

```js
scToday()            // the school's today, YYYY-MM-DD
scDay(value)         // the school's day for any instant / Date / string
scDaysFromNow(n)     // the school's day n days ahead
SCNet.schoolTz()     // the school's zone (school record → device setting → Africa/Lagos)
```

* resolved with **`Intl.DateTimeFormat`**, so DST and half-hour zones are handled by the
  platform, not by arithmetic;
* **103 call sites** converted, in 42 files, including the ten attendance/check-in
  paths, the diary, fees, the exam timetable and the analytics windows;
* `tools/audit-school-day.py` (new, in the gate, across all three deployments) fails the
  build if **any** file computes a calendar day from UTC again, or if a page calls the
  helper without loading it first.

**Proof:** `t59-school-day.mjs` — 17 assertions, device clock pinned, real pages:
00:30 Lagos → the register is dated **today** (and the old expression is shown to
disagree); 23:55 → still today; a New York school at 20:30 → **its own** date, where UTC
says tomorrow; the zone can come from the school record or the device setting; rubbish
input returns `''`, never a fake date.

---

## 3. Issue 2 — two tabs, one token

### What was wrong

`SCNet.session()` refreshed the token when it had under two minutes left — **per tab**.
Supabase **rotates** the refresh token on every refresh, and it enforces a 10-second
reuse interval. The slower tab therefore presented a token the faster one had already
spent; the session was revoked and the next click landed on the login page. Two open
tabs are enough — a phone and a laptop on the same account, or a staff-room machine.

The auth service also rate-limits refreshes **per IP** (150 per 5 minutes by default),
which a household behind one mobile-CGNAT address reaches with a handful of tabs.

### What changed

* A short **lock in `localStorage`** (`sc-refresh-lock-v1`, 15 s, with a 60–190 ms
  jittered second look so simultaneous starts cannot both win).
* One tab refreshes; the others **wait for the new token to appear** in shared storage and
  adopt it — no second network call, no second rotation.
* A `BroadcastChannel` (with a `storage`-event fallback) announces `refreshed` and
  `signedout` so tabs stay in step.
* The lock is always released — including on failure.

**Proof:** `t60-one-refresh-and-signout.mjs` section 1: two tabs ask simultaneously →
**exactly one** refresh, **both** hold the **same** new token, neither reports stale, the
lock is gone.

---

## 4. Issue 3 — the role was being guessed

### What was wrong

```js
role = user.user_metadata?.role || cached?.role || 'student';   // ← invented
```

The shell asked `sc_current_role` **once**. On a line that drops the first request, that
call failed, the profile select behind it failed, and the code wrote `'student'`. A
teacher was then rendered as a learner: no classes, no prep diary, no staff cards — and
nothing on the screen said why. *"It works in school but not at home"* is usually this.

A second, quieter half: pages that asked for their list a moment **before** the role
landed were told "none", and `idcards.html` **cached that empty answer for the life of
the page**.

### What changed

* the role is asked through `SCNet.retry` (4 attempts, backoff) — a timeout is not an
  answer;
* the role **this device already proved** (`sc-last-role`) is used if the server cannot
  answer; a teacher is **never** downgraded to a learner;
* if nothing is known at all, the portal shows an **honest waiting room** — "the portal
  has not been able to confirm who you are yet… nothing has been lost", with a retry —
  instead of impersonating a learner;
* the shell now announces `sc-role-ready` (and sets `data-sc-role` on `<html>`); the ID-card
  page waits longer and re-runs its own load when the identity arrives;
* **an empty list is no longer cached as a fact.**

**Proof:** `t61-role-not-guessed.mjs` — 15 assertions: two dropped requests → still a
teacher; server silent but role remembered → still a teacher; nothing known → the waiting
room appears and the visitor is **not** a student; a late role refetches the list that was
asked for too early.

---

## 5. Issue 4 — a first visit is not an update, and a sign-out must really leave

### What was wrong

```js
navigator.serviceWorker.addEventListener('controllerchange', () => location.reload());
```

On a **first** visit the page starts uncontrolled; the worker installs, `skipWaiting()` +
`clients.claim()` give it control, and that listener **threw the page away and rebuilt
it** — while the visitor was already typing. (`app.js` had the guard; `pwa-install.js`
did not, so the guard was defeated. Found while proving issue 2, which is exactly why the
tests are written against real pages.)

And a sign-out cleared the session but left the previous session's **pages** in the
service-worker cache: on a shared phone, the next person could open the portal offline
and read the last user's dashboard.

### What changed

* `controllerchange` reloads **only** when the page *had* a controller and a *different*
  one took over, once per load, with the same `sessionStorage` flag `app.js` uses;
* `sw.js` gained `PURGE_DOCS`: on sign-out, **every cached document is dropped and the
  shell is kept** (`offline.html`, `index.html`, and all static assets);
* `App.signOut()` broadcasts `signedout`: **every tab leaves**, clears the cached role and
  purges the pages. The device is properly empty.

**Proof:** `t60-one-refresh-and-signout.mjs` sections 3–5: pages are cached while signed in;
signing out in tab A takes tab B to the login page; the dashboard is gone from the cache
afterwards while the offline shell remains.

---

## 6. What was NOT changed

* **No database change.** `database/complete-schema.sql` is byte-identical to V12.82
  (998,213 B). Nothing to run in Supabase for this round — the schema cap is untouched.
* **No new dependency, no CDN, no paid service, no paid Supabase plan.**
* No behaviour was removed: the offline shell, the answer queue, exam mode and the
  polling schedule from V12.82 are unchanged.

---

## 7. Proof — all green

| Suite | Result |
|---|---|
| `tools/verification/t59-school-day.mjs` | **17 passed, 0 failed** |
| `tools/verification/t60-one-refresh-and-signout.mjs` | **13 passed, 0 failed** |
| `tools/verification/t61-role-not-guessed.mjs` | **15 passed, 0 failed** |
| `tools/audit-school-day.py` | **PASSED — 18 checks across 3 deployments** |
| `tools/verify-complete-schema.mjs` | ALL PASS (unchanged file) |
| full gate (`work/run-all-tests.sh`) | **ALL SUITES PASS** |

---

## 8. Upgrading

Upload the files (no database step). Then:

1. **Open the portal on two tabs and sign in.** Both stay signed in; the network panel
   shows **one** refresh, not two.
2. **Sign out in one tab.** The other tab leaves the portal by itself.
3. **Mark a register just after midnight** (or set a phone's clock and zone to check).
   The date is the school's day.
4. **Pull the network for five seconds while a page loads.** A teacher still sees their
   classes — after a retry, or from the role the device already knows — instead of an
   empty learner page.

## 9. Note for the next round

* `preview.js` is loaded by no page in any of the three deployments (`audit-school-day.py`
  reports it as a note). It is a packing question for `audit-repo-parity.py`, not a bug —
  but it should either be wired or dropped.
* The remaining silent catch blocks (`catch(_){}`, 591 of them) are the next honest
  target: most are harmless, a few hide a write that failed.
* Schema headroom is **1,787 B**; the next database object needs space reclaimed first.
