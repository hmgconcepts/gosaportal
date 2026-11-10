/* Shared schema loader for the PGlite harnesses (V12.68).

   The harnesses used to rewrite every `create extension …;` into `select 1;`.
   That was safe while every occurrence was top-level, but the schema also
   contains extension DDL *inside* PL/pgSQL bodies (the self-containment prelude
   and the pg_cron heartbeat). Rewriting there produced invalid SQL and the
   failure looked like a schema defect.

   PGlite ships only `plpgsql`. The cron block guards itself with a
   `pg_available_extensions` check, so on PGlite it self-skips and the extension
   statements inside it are never executed — they only have to parse.

   This loader therefore neutralises an extension statement ONLY when it is
   genuinely at top level, which it determines by tracking dollar-quote state
   across the file rather than matching line starts.
*/
import fs from 'fs';

/** True while the given offset sits outside any $tag$ … $tag$ block. */
function topLevelMask(src) {
  const mask = new Uint8Array(src.length); // 1 = top level
  let i = 0;
  let depthTag = null;
  while (i < src.length) {
    if (depthTag === null) {
      // look for an opening dollar tag
      const open = src.indexOf('$', i);
      if (open === -1) { mask.fill(1, i); break; }
      mask.fill(1, i, open);
      const close = src.indexOf('$', open + 1);
      if (close === -1) { mask.fill(1, open); break; }
      const tag = src.slice(open, close + 1);        // e.g. $$  or  $do$
      if (/^\$[A-Za-z0-9_]*$/.test(tag)) {
        depthTag = tag;
        i = close + 1;
        continue;
      }
      mask.fill(1, open, open + 1);
      i = open + 1;
    } else {
      const close = src.indexOf(depthTag, i);
      if (close === -1) break;                        // unterminated: leave masked off
      i = close + depthTag.length;
      depthTag = null;
    }
  }
  return mask;
}

export function schemaText(p) {
  const src = fs.readFileSync(p, 'utf8');
  const top = topLevelMask(src);

  let out = '';
  let last = 0;
  /* Must start a statement: either the very first non-space token of the file
     or immediately after a semicolon. This stops prose in a -- comment ("some
     loaders rewrite a CREATE EXTENSION into…") being treated as DDL. */
  /* A statement start is either after a semicolon, or the first code on a line
     whose preceding line is blank or a comment — which is how this file is
     formatted. Comments themselves are excluded by requiring that the match
     not be preceded by "-- " on the same line. */
  const re = /(^|;|\n)([ \t]*)create\s+extension\b[^;\n]*;/gi;
  let m;
  while ((m = re.exec(src)) !== null) {
    const at = m.index + m[1].length;
    if (!top[at]) continue;                           // inside a block — leave it
    const lineStart = src.lastIndexOf('\n', at) + 1;
    if (src.slice(lineStart, at).includes('--')) continue;   // it is inside a comment
    out += src.slice(last, m.index) + m[1] + m[2] + 'do $$ begin null; end $$;';
    last = m.index + m[0].length;
  }
  out += src.slice(last);
  return out;
}

/** Load several schema files, neutralising top-level extensions in the first. */
export function loadSchemas(paths) {
  return paths.map((p, i) => (i === 0 ? schemaText(p) : fs.readFileSync(p, 'utf8')));
}

export default schemaText;
