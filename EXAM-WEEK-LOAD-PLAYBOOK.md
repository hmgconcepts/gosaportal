# Exam-Week Load Playbook — free-tier Supabase, a whole school online at once

> **Who this is for.** The school's own administrator. It is written to be read on the
> morning of a prep exam, in five minutes, and it assumes no SQL knowledge.
>
> **What it answers.** Two things the school reported in the same week:
>
> 1. *"At home, during prep exams: some students cannot log in, their answers will not
>    submit, and the portal signs them out in the middle of the paper. In school, with
>    more students, midterm and terminal exams never do this."*
> 2. Supabase emailed us: **"Your project is running out of Disk IO Budget."**
>
> Both are one problem seen from two sides: **the free tier is being asked for more
> requests than it can serve, and the browser is treating every slow answer as a
> failure.** V12.82 fixes the second half in the app itself. This page is the first
> half: what the school can do in the dashboard and in the exam hall.

---

## 1. What the two alarms actually mean

### 1.1 The Disk IO budget (the email from Supabase)

Every Supabase project runs on a **compute size**. The free plan runs on **Nano**: a
shared CPU and up to **0.5 GB of memory** (the whole database server, not the app).

Because Nano is slow at raw disk, Supabase gives it a **daily Disk IO budget**: an
allowance that lets small instances *burst* above their baseline disk performance.
When the allowance is spent:

* the instance drops back to **baseline disk throughput**;
* **every** query gets slower at the same time (it is not one page);
* CPU rises because it is waiting on disk;
* **daily backups and autovacuum can be disrupted** — so the database slowly bloats,
  which makes the next day worse.

That is why the symptoms are confusing: nothing is *broken*, everything is *slow*, and
slow things time out, and a timeout looks exactly like a failure to a browser.

**Supabase's own guide to high disk IO names the usual causes:** memory pressure
pushing pages to swap (every project has ~1 GB of disk set aside for swapping), a low
cache-hit rate (reads going to disk), queries that take more than a second, **more
requests than the instance can handle**, and — the one almost every school portal
has — a **per-row RLS policy check** that re-evaluates `auth.uid()` for every row it
touches instead of once per query.

**The fix is fewer, smaller requests. Not a bigger server.** A bigger compute size
buys a bigger budget; it does not stop a poller that fires every 30 seconds.

### 1.2 "Some students cannot log in" — the rate limiter, not the password

Supabase Auth **rate-limits per IP address**, on these defaults (configurable):

| Operation | Default | Window |
|---|---|---|
| Sign-in / sign-up / password reset | **30 requests** | per 5 minutes, per IP |
| **Token refresh** | **150 requests** | per 5 minutes, per IP |
| OTP / magic-link verification | 30 requests | per 5 minutes, per IP |

Over the limit the answer is **HTTP 429 "Too many requests"** — not "wrong password".

Now the part that explains the school's report exactly:

* **In school**, a class sits behind the school's own connection. A few dozen devices
  share one IP address, and the school is the only user of that connection.
* **At home on mobile data**, a Nigerian network puts **thousands of subscribers
  behind one address** (CGNAT). The school's students are sharing that per-IP budget
  with everybody else on the same carrier mast — including the token refresh, which
  fires about once an hour for every signed-in device in the country.

So the same 60 students, doing the same work, trip a limit at home that they never
touch at school. And the older portal handled a 429 the worst possible way: it showed
"could not sign in", and after a failed refresh it treated the session as dead and
sent the learner to the login page (`SIGNED_OUT` → redirect). **That is the "sudden
logout" in the middle of a paper.**

### 1.3 "Their answers will not submit"

A submission is the heaviest single request the portal makes. If the instance is
throttled by a spent IO budget, or the access token just expired because its refresh
was refused, the request fails — and the learner is left staring at "Submission not
confirmed" while their answers sit in the browser, invisible, with no way to send them
later.

---

## 2. What V12.82 changed in the app (nothing to configure)

| Before | After |
|---|---|
| Every open tab: a **50-row notification select**, an **auth `/user` round trip** and a **message-badge RPC**, every **30 seconds** | **One** `sc_poll_bundle()` call returning three counts, at most once every **2 minutes**, and **never** while the tab is hidden |
| Licence check every **15 minutes** *and on every tab focus* | Once every **30 minutes**, visible tabs only |
| Messages page: badge every 45 s **and** a full thread re-read every 30 s | Same two actions on the app's single scheduler, 3 min / 1 min, paused during a sitting |
| Two Realtime channels per tab, per learner | Same channels, but they stand down during a sitting |
| Every page load: `auth.getUser()` (a network call) up to 4 times | The session is read **locally**; the network is asked only when there is no session |
| A failed token refresh = "signed out" | The session is **kept** and the refresh is retried quietly; the learner is never thrown out |
| A 429 at sign-in = "cannot sign in" | Retried with a wait, and reported as **"the network is busy — press Sign in again"** |
| A failed submission = a dead end with a JSON download | **Queued on the device**, retried on its own, sent automatically when the signal returns, cleared only after the database has it |

Net effect during a sitting, per learner: the portal's background traffic falls from
roughly **three requests every 30 seconds** to **one small request every two minutes**,
and to **zero** while the exam page has the paper open.

---

## 3. The five-minute dashboard checklist (do this before the exam week)

Open the project in the Supabase dashboard → **Project `auptmhagbksebetbxknv`**.

1. **Raise the Auth rate limits** — *Authentication → Rate Limits*.
   This is the single highest-value change for a school on mobile data.
   * **Token refresh**: `150` → **`1500`** (per 5 minutes, per IP)
   * **Sign-ups / sign-ins**: `30` → **`300`**
   * Leave *IP address forwarding* **off** unless the site is behind a proxy you control.
   These are per-IP budgets; a class behind one mast needs head-room.

2. **Look at Database Health** — *Reports → Database health*. Note
   **Disk IO % consumed**, **Memory**, **Swap** and **CPU**. If memory sits near the
   top of the chart the database is being read from disk on every query, and no amount
   of app tuning will fix that — that is the one case where a compute step up is the
   honest answer.

3. **Prune the tables that only grow** — in the portal, *Platform Health → Load & Disk
   IO → 🧹 Prune old notices*. This deletes notifications and login-audit rows older
   than the window you type (minimum 30 days). Nothing a report reads is touched.

4. **Read the load report** — same page, **↻ Read the report**. It names the table
   being written most and the table being read without an index. If a table you do not
   recognise is at the top of the writers list, send that page (or the JSON) with a
   support request: that is the table to fix.

5. **Tell learners one thing**: *close the tabs you are not using.* Five open tabs of
   the portal is five times the background traffic on the same phone.

---

## 4. What to do on the morning of a paper

**For the school**

* Use **one device per learner** where you can, and close the portal home page while
  the paper is open — the exam page itself keeps its own (much lower) traffic.
* Do not ask the whole class to sign in at the same second. Open the window five
  minutes early and let them trickle in; the limiter refills in minutes.
* If a learner sees *"the network is busy"*, tell them to **wait a minute and press
  Sign in again**. Nothing is lost, and the password is not wrong.

**For the learner, if the paper will not send**

1. **Do not close the tab.** The banner at the bottom of the screen tells you the
   truth: *"answers saved on this device, will send when the signal returns"*.
2. Wait for the signal, then press **↻ Try sending again now**, or simply reload the
   exam page — it resends anything still queued, from this device.
3. If the phone must be handed in, press **⬇ Download backup** and give the file to the
   invigilator. It contains the answers, never the answer key.

**For the invigilator**

* A paper that never reached the server can be flushed by the learner on the same
  device later (`cbt.html` → pending queue, or simply opening `cbt-exam.html`), and a
  copy that reached the *server's* pending table can be flushed by a tutor from the CBT
  manager. Two independent safety nets — that is deliberate.

---

## 5. What "healthy" looks like afterwards

Watch these for 48 hours after the changes. All are in *Reports → Database health*:

| Signal | Healthy | What it means if it is not |
|---|---|---|
| Disk IO % consumed | flat or falling through the day | another request source exists (another app on the same project, a spreadsheet script, a monitoring tool) |
| CPU | low and stable | CPU pinned with low IO = a query doing too much work, not too many queries |
| Memory | comfortably below the top | memory pressure = reads hitting disk; a compute step is the honest fix |
| Swap | near zero | swap is disk IO you are paying for twice |
| Response time | steady through the evening | a rising line at exam time is the pollers you just removed — check the deployed version |

---

## 6. If it is still slow after all of that

In this order — each step is a real fix, not a workaround:

1. **Check the deployed version.** Platform Health → Schema Doctor shows the installed
   pack. It must say `v12.82`. A device still running `v12.81` keeps the old 30-second
   pollers (the service worker cache is versioned, and a reload picks it up).
2. **Prune again** with a shorter window (30–60 days). Notifications are the one table
   that grows every day and is read by every device.
3. **Run the load report and look at `top_full_scans`.** A table with millions of rows
   read and few index scans is a missing index — send that row.
4. **Reduce devices online**, not features: five tabs per learner is the single most
   common cause in a school where this has happened before.
5. **Only then consider compute.** A step up from Nano gives more memory and a bigger
   burst budget; it is the right answer when *memory* is the constraint, and a waste of
   money when the constraint is a poller.

---

*Written for release V12.82. The numbers quoted for Supabase (Nano, 0.5 GB, the
Disk IO budget, the auth rate limits) are the documented defaults at the time of
writing; if the dashboard disagrees with this page, the dashboard is right.*
