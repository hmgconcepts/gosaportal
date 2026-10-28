# GitHub Upload Map

The three source folders retain their cloned `.git` histories locally. To update the existing public repositories, copy/commit the corresponding folder contents:

| Local folder | Target repository |
|---|---|
| `school-connect-generator/` | `https://github.com/hmgconcepts/schoolconnect` |
| `generated-sites/gosa/` | `https://github.com/hmgconcepts/gosa` |
| `demo-site/` | `https://github.com/hmgconcepts/schoolconnectdemo` |

Recommended commands inside each folder:

```bash
git status
git add -A
git commit -m "School Connect V5 cumulative CBT, reports, demo and build fixes"
git push origin main
```

Review `git diff --check` and ensure no service-role key, real password or real student record is staged. Public Supabase anon keys are technically public by design, but confirm they point to the intended projects and RLS is enabled.

Do not commit the top-level `verified-builds/` ZIPs into all three repositories unless release binaries are intentionally wanted. They are build evidence/deliverables, not runtime requirements.
