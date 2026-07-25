# School Connect V5 — Test and Audit Report

**Audit date:** 2026-07-25 (Africa/Lagos)

## Automated results

| Suite | Result |
|---|---:|
| V5.2.1 SQL/link/parity/security contract audit | 45 passed, 0 failed |
| CBT UTME tab simulation | 9 passed, 0 failed |
| CBT browser scoring/parser unit tests | 11 passed, 0 failed |
| Executed V5.1 SQL grading engine (PGlite) | 10/10, 100%, 5 correct; idempotence, historical regrade, redaction and missing-key guard passed |
| Report-output unit tests | 5 passed, 0 failed |
| Bulk CBT → canonical report_scores tests | 4 passed, 0 failed |
| Sample/receipt/fee workflow regression | 12 passed, 0 failed |
| Role-navigation regression | passed |
| Generator packaging contract | passed |
| Traditional real JSZip build | 184 entries; 0 broken links; 0 orphans |
| Modern real JSZip build | 389 entries; 0 broken links; 0 orphans |
| PostgreSQL parsing | complete schema 970 statements; demo seed 34 top-level statements |
| Demo seed/schema column contract | 0 missing tables/columns |
| Shared runtime parity across generator/GOSA/demo | passed |

Run everything from the generator repository:

```bash
./verify.sh
```

## Tested CBT cases

- Correct answer stored as letter, candidate submits letter.
- Correct answer stored as letter, candidate equivalent option text.
- Correct answer stored as option text, candidate submits letter.
- `true-false` alias normalisation and letter/text equivalence.
- Numeric tolerance pass/fail.
- Multi-select exact set, order-independent; partial set rejected.
- Mixed question grading totals 100% when all answers are correct.
- Subject breakdown recovers two stable subject groups.
- Random/shuffled payload carries original bank index.
- Static server contract verifies canonical and v2 paths use the fixed matcher.

## Tested document cases

- Grade thresholds match the supplied samples.
- Student report includes school identity, score table, affective and psychomotor domains, comments, signatures and stamp.
- Class broadsheet has rotated subject headings, totals, averages, positions and grading legend.
- Subject broadsheet has average, high, low and pass-rate statistics plus sign-off.
- Receipt has header/logo/contact, reference/date/student/term/method, total, amount paid, remaining/full-paid state and authorised signature.

## Workflow audit

- Generator rich templates no longer drift from critical reference pages.
- All three repositories share identical CBT/report/CRUD/help engines and canonical schema/seed.
- Static local links resolve in generator, GOSA and demo.
- Candidate exam is network-first after tab repair and retains offline fallback.
- Service-worker/cache headers force updated grading code to replace old cached assets.
- Demo records cover core, academic, finance, communication and enterprise pages.

## Security audit notes

- Public question getter strips top-level answer/explanation keys.
- Browser-supplied marks are not trusted by canonical SQL scorer.
- Submission retries use client-reference idempotency.
- Role/page checks complement RLS; they do not replace it.
- No paid AI API endpoint/key dependency was detected.
- Public Supabase anon keys are expected; service-role keys must never be committed.

## Boundaries of this audit

- No owner/service-role credentials were supplied, so the repaired SQL was syntax/contract tested but not applied to the user’s live projects by this agent.
- The live authenticated pages could not be exercised as real roles without account credentials.
- Visual output structure was regression-tested; printer/browser-specific pagination should still be accepted on the school’s actual devices.
- Provider free-tier concurrency and quotas require a deployment-specific load test.

## Manual acceptance required after deployment

Use the checklist in `DEPLOYMENT-GUIDE-V5.md`, particularly a disposable live CBT with mixed answer-key formats, a repaired old multi-subject exam, all five demo roles and four printed outputs.
