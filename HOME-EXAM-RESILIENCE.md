# Why a prep exam works on the school router and fails at home — and the standards it is now held to

**Version:** V12.86 · **Date:** 8 November 2026 · **Audience:** the school, the bursar, whoever maintains the
deployment

This document answers three questions the school asked together:

1. *"Learners doing prep exams at home on different networks hit glitches and errors."* — What is different
   about a home network, and what international standards exist for it?
2. *"Re-analyse why prep exams at home fail while in-school CBT/terminal exams on the school router did
   not."* — The honest answer, layer by layer.
3. *"Fix everything in the Supabase email while staying on the free tier."* — See `FREE-TIER-BUDGET.md` §7
   for the quota answer; §5 below is the part of it that belongs to exam delivery.

Everything below is either **(a)** a standard the platform is now measured against, or **(b)** a change that
is in the shipped code and proved by a test. Nothing is claimed on the strength of "it should work".

---

## 1. The one-sentence answer

The school router and the home connection do not differ mainly in *speed*. They differ in **who else is on
the path, how long the path stays the same, and whether the device can be trusted to stay awake**. The
platform was built around the assumption that a page that is open stays open and that a request either
succeeds or fails. Neither assumption survives a phone call at home. V12.86 removes both assumptions from the
exam path.

---

## 2. Layer-by-layer: what the school router gives you for free

| Layer | In school (one router) | At home (each family) | What it caused | The standard, and the fix |
|---|---|---|---|---|
| **Path & NAT** | One public IP, one NAT, stable route; the database sees one peer | A different ISP per family, CGNAT, routes that change mid-paper, IPv6/IPv4 flapping | Requests failed mid-flight and were *silently* half-done | **Idempotency**: a submission carries `client_ref` and is deduplicated server-side, so a retry can never score twice. (RFC 9110 §9.2.2 idempotent methods; the WAL queue in `SCNet`) |
| **Retries** | Rarely needed — a failure meant a real fault | Transient failures are constant; naive retry storms make them worse | Page spun, learner pressed Send repeatedly | **Exponential backoff with full jitter, capped attempts** — AWS Well-Architected **REL05-BP03**; the exam loader already backs off 5× (400 ms → 6 s + jitter), and the sender queues instead of blocking |
| **Clock** | Device clock roughly right; session short | Device clocks drift, and a locked screen freezes JavaScript timers | "0:00" on return, then an instant submit | **Server as the clock of record**: `serverSkew` from `server_now`, re-based on reconnect via `sc_cbt_window_state`; the local timer is display only |
| **Tab lifetime** | Desktop/laptop usually awake | Phone OS discards backgrounded tabs under memory pressure — *no* `visibilitychange`, *no* `pagehide` | The sitting was charged for the whole phone call | **W3C Page Visibility Level 2** covers the visible cases; the invisible case needed a **heartbeat** (V12.86) that lets a rebooted page reclaim the away time, capped at 30 min per sitting |
| **Interruption semantics** | None — the learner is being invigilated | A call, a notification, a sibling opening a video | Blur counted as cheating; escalation submitted the paper | **1EdTech Proctoring Services v1.0** defines an explicit **`resume`** action for "a previously paused attempt"; V12.84/V12.86 implement exactly that policy: one flag per away period, escalation held until the candidate returns, nothing sent while hidden |
| **Attempt model** | One sitting per exam, one device | Two tabs is a common accident; a shared phone is common | A second attempt overwrote the first | **1EdTech QTI 3** item-session model: an attempt has a *state* (`suspended` → `resumed` → `final`) rather than being an event. The device lock (`takeSitting`) plus the persisted draft make the second tab a *resume*, not a new attempt |
| **Content availability** | Paper cached on the school LAN | Mobile data drops between questions | "Exam service unavailable" at the worst moment | **Offline-first cache**: `cbt_get_public_exam_v7` is cached per exam code for 24 h, and a network failure falls back to the last verified copy, saying so |
| **Answer durability** | Laptop stays on | App switch, low battery, storage full | Answers lost | **WCAG 2.2 §3.3.4 / 2.2.1-adjacent practice**: never lose user input on interruption; draft written on every answer, with an explicit warning when the device refuses to store it |
| **Report/score integrity** | Scores written once, in school | Late submissions arrive after the window | Late papers rejected → the exam is lost anyway | Server accepts a submission after the close (only *starting* is closed), and the interruption record travels with the attempt so a tutor can see *why* it arrived late |

---

## 3. The standards, listed

These are the published standards and practices the home-exam path is now checked against. Where the
platform does not implement one, it says so (§6).

| # | Standard / practice | What it governs here | Where it is implemented |
|---|---|---|---|
| 1 | **1EdTech QTI 3.0 (Assessment, Section and Item Information Model)** — item-session lifecycle, `completionStatus`, resume of a suspended session | An attempt is a *stateful session* that can be suspended and resumed | `cbt_exam_answers` autosave, draft + deadline persistence, `takeSitting` |
| 2 | **1EdTech Proctoring Services v1.0** — Assessment Control Service, `action = resume` | A paused attempt is resumed explicitly, not silently restarted; integrity events are recorded, not inferred | `Exam.onViolation`, `Exam.pauseForInterruption`, `interruption_log` in the payload |
| 3 | **1EdTech LTI 1.3 / Advantage (AGS, NRPS)** — grade/membership exchange | Not used: the platform is self-contained, no LMS | — |
| 4 | **AWS Well-Architected REL05-BP03 — retry with exponential backoff, jitter, capped attempts** | Every retry in the exam path | exam loader (5 attempts + jitter), `SCNet` WAL flush, `FeeDoctor` sequential fixes |
| 5 | **Idempotency of retried writes (RFC 9110 §9.2.2; `client_ref` as an idempotency key)** | Submitting twice cannot score twice | `cbt_submit_with_wal` / `cbt_submit_v6` dedupe on `client_ref` |
| 6 | **W3C Page Visibility Level 2** | Hidden ≠ gone; the clock must not run | `visibilitychange`, `pagehide`, `pageshow` handlers |
| 7 | **W3C Service Workers / offline-first (cache-then-network for content, network-then-queue for writes)** | The paper opens when the line is bad | `sw.js`, exam cache, `SCNet` |
| 8 | **WCAG 2.2 — 3.3.4 Error prevention, 2.2.1 Timing adjustable, 3.2.x Predictable** | A candidate is never punished for an interruption they did not cause; every timed state is announced | pause banner, "time is up — send my answers" door, idle-guarded sender |
| 9 | **PostgreSQL `NOTIFY pgrst, 'reload schema'` discipline** | A newly deployed function must be visible immediately, or the page reports a false "not installed" | last statement in `complete-schema.sql` (tested by `tmp-notify-order.mjs`) |
| 10 | **Supabase free-tier limits (500 MB DB, 5 GB egress, 1 GB logs ingest, pause after 7 days idle)** | The school stays on ₦0 | `FREE-TIER-BUDGET.md` §7 |

---

## 4. What was actually changed in V12.86 (and what was already right)

| Reported symptom | Was it a real defect? | What V12.86 changed |
|---|---|---|
| "Answers lost when the phone rang" | Partly — V12.84 had already stopped the auto-submit, but a **discarded tab** still lost the minutes | Heartbeat + boot credit (`t69`) |
| "It submitted itself" | Yes, three routes; two closed in V12.84, the third (single 120 s timer that fired unseen) closed now | Re-arming, visible-only, idle-guarded sender |
| "Exam service unavailable at home" | Already handled by the 5× backoff + cached copy (V12.60) | Nothing new; proved by `t67` |
| "Wrong time left after a call" | Already handled (server re-base) | Nothing new; the boot credit adds the tab-discard case |
| "Two attempts on one phone" | Already handled (device lock) | Nothing new |

---

## 5. The part of the Supabase email that belongs to exams

The email is about **Disk IO Budget** on a **NANO** instance (ref `auptmhagbksebetbxkvn`, `eu-west-1`), and the
dashboard shows **Log Ingestion 1.01 / 1 GB — the only resource over its limit**. Exam delivery contributes
to both, so V12.86 keeps it cheap on purpose:

* the countdown is not a request — one `sc_cbt_window_state` call per reconnect, never a poll per second;
* drafts are written to the device, not to the database, so a 60-question paper costs one insert per answer
  change at most (debounced), not a stream;
* the submission is one call, and a retry is the *same* call (idempotent), so a bad line does not multiply
  write IO;
* the repair and doctor functions are administrator-initiated and set-based (one statement per check), not
  per-learner loops.

`FREE-TIER-BUDGET.md` §7 lists the free remedies for the Disk IO email in order of effect. None of them
requires an upgrade.

---

## 6. What is still not covered (said plainly)

1. **No client-side encryption of the draft on the device.** A draft is plain JSON in `localStorage`. On a
   shared family phone, another person with the unlocked device could read a candidate's answers. Mitigation
   in place: the draft key includes the admission number, it is deleted on submit, and the payload carries no
   answer key. A proper fix is WebCrypto with a per-sitting key — not done.
2. **No offline *submission*** beyond the queue. If the network never returns before the tab is closed, the
   answers stay on that device until it is opened again or the learner downloads the backup file the page
   offers.
3. **No bandwidth budgeting.** A paper with many images is heavy on 3G; the platform does not yet warn the
   tutor at authoring time.
4. **The interrupt-time cap (30 min) is a compromise.** It is enough for a call, a power cut or a data
   outage; it is not enough to hide an hour of looking things up. The record of every interruption is
   submitted with the attempt, so a tutor can still judge.
