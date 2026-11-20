# Student/staff ID card print guide

## What each button makes (V12.80)

The action bar carries a **scope**; every button works on that scope, and the
line above the buttons always states what the run will contain.

| Scope | What it makes | Use it for |
|---|---|---|
| **This person** | front and back of the one record on screen | printing a card for the learner or staff member you just picked |
| **A class / section** | everyone in the class box, optionally narrowed by the **Section / arm** box | one class, or one arm of a class (JSS 1 · A) |
| **Everyone in this list** | whatever the class box + search box currently select | "find them, then print what you found" |
| **All students** | the whole student roll, from any tab | the yearly student-card run |
| **All staff** | the whole staff roll, from any tab | the staff-card run |

- **⬇ Download PDF** makes the file for the scope. **🖨 Print ALL** sends that same
  file to the printer. **🖨 Print ID Card (front + back)** is always exactly one
  card — the person on screen — whatever the scope says.
- The **All students / All staff** scopes are for the admin tier. A learner or a
  parent is told no, and the list they may see is untouched: a learner's scope is
  their own card, a parent's is their linked children.
- The class box holds a **class**; it is ignored by an "All staff" run, because a
  class means nothing to a staff record. To print one department, switch to the
  **Staff** tab — the same box then lists departments, staff types and roles.
- A class or section that matches nobody prints **nothing** and says so. A filter
  never widens into the whole school.
- If a record has no photo on file the scope line says how many, and those cards
  print with the design's own initial-letter tile rather than a blank box. Photos
  stored as Google Drive links are read through the Drive preview hosts; a photo
  host that refuses to be read is reported, not silently blanked.

## Finished card formats

The ID Cards page now offers ISO-size presets and custom finished dimensions:

| Preset | Landscape | Portrait |
|---|---:|---:|
| ISO/IEC 7810 ID-1 (common bank/plastic card) | 85.60 × 53.98 mm | 53.98 × 85.60 mm |
| ISO ID-2 | 105 × 74 mm | 74 × 105 mm |
| ISO ID-3 | 125 × 88 mm | 88 × 125 mm |
| Custom | enter width × height in mm | enter width × height in mm |

Landscape/portrait changes the design orientation, not the nominal finished dimensions. For a portrait layout, choose the **Vertical** card design template for best visual balance. ISO/IEC 7810 describes physical ID card characteristics; for plastic ID-1 stock the nominal thickness is about 0.76 mm. Printer stock, lamination, chip technology and cut tolerances depend on the card manufacturer and printer; the web app controls the printed layout, not the physical media.

## Print modes

- **One student per page — front + back together:** each student gets one paper sheet; both finished-size faces sit side-by-side or stacked. This is suitable for proofing, paper cards, cutting, or a sheet-fed workflow.
- **Duplex plastic — consecutive front/back pages:** each student's front is one page and back is the immediately following page, then the next student's pair. Use the printer's duplex setting and confirm its flip edge on scrap stock before printing a class.
- **Auto-fit on sheet:** chooses side-by-side when the pair fits, otherwise stacks the two cards. Forced Side-by-side/Stacked settings are validated; oversized cards are not silently scaled.
- **Custom paper:** use A4, US Letter, or a custom sheet size. The app reports when the selected physical cards cannot fit the chosen sheet.
- **Trim guides:** toggle cut marks around the finished card frames.

## Reliable output checklist

1. Select the finished card preset/orientation and paper size/orientation.
2. Choose Paired or Duplex mode, then print one test card first.
3. In the print dialog set scale to **100% / Actual size** (not “Fit to page”), disable browser headers/footers, and verify card dimensions with a ruler.
4. For plastic cards, use compatible ID-1/ID-2/ID-3 stock and the printer manufacturer's alignment/duplex instructions. Do not assume a web-generated PDF controls card thickness or laminate settings.
5. QR codes on ID cards are generated locally from the holder identifier; the card generator does not send student names/IDs to an external QR service. The Code 39 barcode remains available as a second scanner-friendly identifier.

The paired and duplex print paths use one student per print unit and fixed millimetre dimensions. A student's back is never allowed to flow onto the next student's page.
