# School Connect — V12.80

**20 November 2026 · ID cards: the person's photograph, the person you picked, and one run per family and per section**

Seven reports came in about one page. Two were real defects that had been hiding
behind each other, and the rest were things the page could not do at all.

---

## 1. The cards had no photographs

**What was reported.** Every download, print and proof sheet came out without the
student's or the staff member's picture — a grey box where the face should be.

**Why.** A picture from another origin has to be read *byte for byte* before it
can be drawn into a canvas; a canvas that has merely *seen* a cross-origin
picture cannot be read back, and the browser refuses rather than handing over a
blank card. The old loader tried exactly one route — a `fetch` of exactly one
URL — and then painted a grey rectangle with the word "photo" on it. Google
Drive, which the page itself advertises, answers that request with no CORS
header at all. On a real school, therefore, **every Drive photo became a grey
box** — and a photo hosted anywhere else that does not send CORS headers did the
same.

**Fix.** Each picture is now tried through every route that can work:

1. the card's own URL — `fetch`, then a `crossOrigin` `<img>`, then a plain
   `<img>` drawn into a canvas (same-origin needs neither);
2. the card's documented **second source** (every template writes `data-alt`;
   for a Drive link that is `lh3.googleusercontent.com`, which *does* allow the
   read);
3. and if every route fails, the **card's own fallback** — the initial-letter
   tile the preview shows — instead of a grey rectangle pretending to be a photo.

Failures are counted and published (`IDCardRaster.lastReport()`), so a school is
told which records have no usable artwork instead of discovering it at the
printer.

## 2. "Print ID Card" printed somebody else

**What was reported.** Pick a learner, press **🖨 Print ID Card (front + back)**,
get a different learner's card.

**Why.** `print()` asked for the whole loaded list and then printed element `[0]`
— the alphabetically first learner in the school. The record on screen was never
consulted.

**Fix.** "One card" now means the person on screen and nothing else: the row
picked in the dropdown, or the details typed into the form. With nothing picked
it says so instead of printing a stranger.

## 3–5. Bulk staff, bulk students, a class, a section, one person

The page could only ever print "whatever list it happened to be holding", and
the staff list was only reachable by switching tabs first. The action bar now
carries an explicit **scope**:

| Scope | What it makes |
|---|---|
| **This person** | front and back of the one record on screen |
| **A class / section** | every learner in the chosen class, or in one arm of it |
| **Everyone in this list** | whatever the class box + search box currently select |
| **All students** | the whole student roll, from any tab |
| **All staff** | the whole staff roll, from any tab |

The last two load the other family on demand (the admin tier only — a learner
and a parent are refused, and their own list is untouched). A new **Section /
arm** box sits beside the class filter, so `JSS 1` is the class and `JSS 1 · A`
is the section; an arm that does not exist narrows to nothing and says so rather
than quietly printing the whole school.

A plain-English line above the buttons always states the run: *"14 student cards
— JSS 1 · A. 2 of them have no photo on file."* The file name follows the run
(`staff-id-cards-all-staff-<date>.pdf`, `student-id-cards-jss-1-a-<date>.pdf`).

## 6. The front of the card was half empty

**What was reported.** "The front page doesn't have complete information — some
relevant information is missing."

**Why.** The design was laid out on the wrong canvas. The fitting search kept the
**widest** canvas the design still fitted inside, on the theory that wider means
bigger type. A template sets its type, photo and QR in pixels, so its content
height stops growing with the canvas (the premium design: 360 px of content at
every width from 480 px up) while the canvas height keeps growing. The widest
fitting canvas was therefore the **emptiest** one: a premium card 780 px wide
held 360 px of design and left a third of the card blank.

**Fix.** The search now keeps the **smallest** canvas that fits. The design fills
the card by construction, and — because that canvas is scaled up most into the
face — the type on paper is larger. Measured: the card now fills **100 %** of its
face where it used to fill 73 %.

The card is also laid out at exactly the pixel size the preview uses and only the
*pixel density* is raised for print. Laying it out at 300 dpi had been a
different layout, not a bigger one — the same reason a downloaded card could
disagree with the screen it was approved on.

## 7. When the browser cannot photograph the card at all

Some browsers (older WebViews, some Safari versions) will not rasterise an SVG
`<foreignObject>`, so the photograph of the card fails and the page falls back to
the older vector renderer. That renderer used to be handed `photo: null` and only
a name and a number — the "no pictures and half a front" report in its purest
form. It now receives the photo (loaded with the same tolerant loader) and every
field the record holds.

---

## What was proved

`tools/verification/t54-idcard-round25.mjs` — **29 passed, 0 failed**. It opens
the real page and:

* serves a portrait from a **different origin** and finds its colour **inside the
  downloaded PDF** (9.4 % of the face, against 0.0 % for the same card with no
  photo — a measurement, not a threshold);
* selects the **third** learner and proves Print produces exactly one card, and
  that it is that learner's;
* runs **all students** (3 cards, `student-id-cards-all-students…pdf`) and **all
  staff** (2 cards, staff numbers and departments, `staff-id-cards-all-staff…
  pdf`) from the one page;
* runs a **class** (3) and **one section** of it (2 and 1), and proves a section
  that does not exist prints nothing;
* makes a **single staff card** with its department on it;
* measures that the design reaches the bottom of the card and fills **100 %** of
  the face;
* points a photo at a host that cannot be read and proves the card is still
  produced and the missing picture is counted.

The existing suites still pass unchanged: **t39** (one box, nothing cropped),
**t42** (13 designs, one card, two faces, one size), **t47** (self-service),
**t50** (staff cards list staff), **t51** (the download is the preview, and it
opens in CorelDRAW), **t52** (prep window), plus the schema gates: verifier
**ALL PASS**, upgrade audit **ALL PASS**, `t53` **23/0**, platform audit **513/0**.

## Database

`database/complete-schema.sql` — V12.80. The only schema change in this release
is the version row a school reads back (`select … as status`); the file is
otherwise byte-for-byte the V12.79 schema, which already upgrades an older
install instead of failing with `42P13`. Re-run it as usual: nothing is dropped,
nothing is touched.

## Updating

1. Paste `database/complete-schema.sql` into the SQL Editor and Run.
2. Upload the new files over the old ones.
3. On a phone, press **Update now** when the bar appears.
4. Open **ID Cards** and look at the scope line: it now names the run before you
   press anything.
