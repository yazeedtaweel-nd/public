# Migrations (Approach 2)

Numbered SQL scripts plus a migration ledger (`etl.SCHEMA_MIGRATION`). Apply against the **existing** DWH database before deploying the Party SSIS package.

## Layout

| Path | Purpose |
|------|---------|
| [001_etl_control.sql](001_etl_control.sql) | `etl` schema, control tables, `VW_JOB_TABLE_STATUS` |
| [002_seed_party_package.sql](002_seed_party_package.sql) | Party job + six `ETL_JOB_TABLE` rows (no global parameters) |
| [../scripts/bootstrap_ledger.sql](../scripts/bootstrap_ledger.sql) | Creates `etl` schema + `SCHEMA_MIGRATION` (runner only) |
| [../scripts/Apply-Migrations.ps1](../scripts/Apply-Migrations.ps1) | Windows runner |
| [../scripts/apply-migrations.sh](../scripts/apply-migrations.sh) | macOS / Linux runner |

## Apply order

1. Bootstrap ledger (automatic in the runner)
2. `001_etl_control.sql`
3. `002_seed_party_package.sql`
4. Deploy SSIS `.ispac` (`DimParty.dtsx`)
5. Bind catalog Environment variables
6. Run the package

Scripts already recorded in `etl.SCHEMA_MIGRATION` are skipped.

## How to run

Requires `sqlcmd` on PATH.

**Windows (trusted):**

```powershell
cd etl-control\scripts
.\Apply-Migrations.ps1 -Server SQLDWH01 -Database SaudiRe_DW
```

**macOS / Linux:**

```bash
cd etl-control/scripts
chmod +x apply-migrations.sh
./apply-migrations.sh -S SQLDWH01 -d SaudiRe_DW
# or SQL auth:
./apply-migrations.sh -S SQLDWH01 -d SaudiRe_DW -U myuser -P '***'
```

## Verify

```sql
SELECT SCRIPT_NAME, APPLIED_DATE, APPLIED_BY
FROM   etl.SCHEMA_MIGRATION
ORDER BY SCRIPT_NAME;

SELECT j.JOB_NAME, t.TABLE_NAME, t.LOAD_ORDER, t.LOAD_TYPE, t.WATERMARK_TYPE,
       t.SOURCE_OBJECT, t.TARGET_OBJECT
FROM   etl.ETL_JOB AS j
       INNER JOIN etl.ETL_JOB_TABLE AS t ON t.JOB_ID = j.JOB_ID
WHERE  j.JOB_NAME = N'DIM_PARTY_LOAD'
ORDER BY t.LOAD_ORDER;
```

## Adding a later migration

1. Add `003_....sql` (zero-padded, ascending).
2. Re-run the Apply-Migrations script — only the new file runs.
3. Never edit an already-applied script on a shared environment; add a new numbered file instead.
4. Never overwrite `WATERMARK_VALUE` in seed migrations after go-live.

## Notes

- Global `ETL_PARAMETER` seed is intentionally omitted (use SSIS project/catalog parameters).
- Confirm `JOB_NAME` / `PACKAGE_NAME` (`DIM_PARTY_LOAD` / `DimParty.dtsx`) with the SSIS project before first apply.
- Confirm `LOAD_TYPE` / `WATERMARK_TYPE` against Change Tracking on SICS source tables.
