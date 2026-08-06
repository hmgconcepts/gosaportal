# 📚 Term-End & History Guide — keeping every term's records forever

School Connect **never deletes a finished term's data**. Results, report scores,
fees, attendance and promotion decisions all carry their **Term + Session**
labels, so switching to a new term simply changes the *default* period that
forms auto-fill — the old records remain in the database and can be reopened,
re-printed and analysed at any time.

This guide is the recommended term-end routine plus exactly **how to reopen
any previous term** on each page.

---

## 1. How to view or regenerate ANY previous term

| Page | How to reach past records |
|---|---|
| **Report Cards** | Pick the class, then simply choose the OLD **Term** and **Session** in the dropdowns → **Load / Build**. Students who have since been promoted or graduated appear with a **🎓 moved on** badge — their cards and broadsheets still regenerate in full. |
| **Academic Records / Broadsheets** | Same term/session dropdowns — select any period ever used; the broadsheet rebuilds from the stored scores. |
| **Attendance** | Choose the class and **pick any past date** — the register loads *as it was saved* that day (green banner = marks on file). You can correct and re-save history. |
| **Fees** | Fee payments keep their term/session; use the table **Filter:** dropdowns (Term / Session) or the search box to slice any period. Receipts re-print from the row's Print button. |
| **Promotion / Graduation** | Every applied decision stays on the page with status `applied` and its term/session stamp. Use the **Filter:** dropdowns (class, action, status, term, marks ≥/≤) to review a past exercise. |
| **Results (score sheets)** | The results table stores every term's rows; filter by Term/Session from the filter bar above the table. |

> **Why this works:** the database keys academic rows by *(class, term,
> session)* — a new term adds new rows; it never overwrites old ones. The
> current period only controls **auto-fill defaults**, not visibility.

---

## 2. Recommended end-of-term routine (15 minutes)

1. **Freeze scores** — Report Cards → confirm each class/subject grid is complete; run *🔎 Audit / Clear Unwanted Scores* once.
2. **Print / archive** — bulk-print class report cards (Admin → *Print ALL*), and export the results table (⬇ Export) for your own file.
3. **Backup** — Admin Data → Google Drive **Sync now** (or Export Full Archive). One click stores a sealed copy outside Supabase.
4. **Promotions** — Promotion page → *⚙ Auto-promote (by exam)* → review the drafts (use the filter bar: class / marks ≥ benchmark) → *✅ Apply promotions*. Graduating students are **automatically filed into Alumni** with their graduation year.
5. **Advance the period** — Academic Setup → mark the NEW term/session as *current*. Every form now auto-fills the new period; the old term stays fully accessible per the table above.
6. **Fees rollover** — School Fees → duplicate the fee structure for the new term (amounts editable), so the fees page and receipts pick up the new expectations.

---

## 3. End-of-session extras

- **Graduates** — after Apply promotions, check **Alumni**: the graduating class is filed there with the session's year (e.g. 2025/2026 → 2026).
- **Transcripts** — the Transcripts module (Documents) summarises a learner's sessions for leavers.
- **Transfer certificates** — issue from the Transfer Certificate module; the student's history remains readable even after deactivation.
- **Insights** — Analytics reads across ALL terms, so year-over-year attendance and fee-collection comparisons work out of the box.

---

## 4. What is (deliberately) removed from history

Only two things ever hide historical rows:

1. **Deleting a student** (Students → Delete) — their scores are swept by the
   clean-data lifecycle and a sealed copy is filed in the **Archive Vault**
   (module_records → student_archive) first, so even that is recoverable.
2. **🧹 Sweep Ghost Report Sheets** — admin-only, removes rows belonging to
   *deleted* columns/students only. Promoted/graduated students are **never**
   treated as ghosts.

Everything else — every term, every session — stays queryable forever, within
Supabase free-tier limits (see FREE-TIER-CAPACITY-GUIDE.md: ~500 students ≈
70–135 MB per YEAR, so many years fit comfortably).
