/* ============================================================
   Migration: 002_seed_party_package.sql
   Seed ETL_JOB + ETL_JOB_TABLE for the Party SSIS package.
   Requires: 001_etl_control.sql
   Re-runnable: guarded by JOB_NAME / TABLE_NAME.
   No global ETL_PARAMETER rows (config lives in SSIS / catalog).

   WATERMARK_VALUE is left NULL (never loaded). Do not overwrite
   watermarks in later migrations after go-live.
   ============================================================ */

/* ------------------------------------------------------------
   Party package (job)
   Confirm JOB_NAME / PACKAGE_NAME with the SSIS project.
   ------------------------------------------------------------ */
INSERT INTO etl.ETL_JOB
    (JOB_NAME, PACKAGE_NAME, EXECUTION_ORDER, DESCRIPTION)
SELECT v.JOB_NAME, v.PACKAGE_NAME, v.EXECUTION_ORDER, v.DESCRIPTION
FROM (VALUES
    (N'DIM_PARTY_LOAD',
     N'DimParty.dtsx',
     CAST(10 AS SMALLINT),
     N'Party package: Country, User, Company, Broker, Cresta Zone, Original Insured.')
) AS v (JOB_NAME, PACKAGE_NAME, EXECUTION_ORDER, DESCRIPTION)
WHERE NOT EXISTS (SELECT 1 FROM etl.ETL_JOB AS j WHERE j.JOB_NAME = v.JOB_NAME);
GO

/* ------------------------------------------------------------
   Tables inside DimParty — each has its own watermark.
   LOAD_ORDER: Country first (FK for Company / Broker / Cresta).
   LOAD_TYPE / WATERMARK_TYPE: confirm against CT enablement on SICS.
   ------------------------------------------------------------ */
INSERT INTO etl.ETL_JOB_TABLE
    (JOB_ID, TABLE_NAME, SOURCE_OBJECT, TARGET_OBJECT,
     LOAD_TYPE, WATERMARK_TYPE, LOAD_ORDER, DESCRIPTION)
SELECT j.JOB_ID, v.TABLE_NAME, v.SOURCE_OBJECT, v.TARGET_OBJECT,
       v.LOAD_TYPE, v.WATERMARK_TYPE, v.LOAD_ORDER, v.DESCRIPTION
FROM (VALUES
    (N'DIM_PARTY_LOAD', N'COUNTRY',
     N'SICS.dbo.LEGAL_AREA',         N'dbo.DIM_COUNTRY',
     'FULL', 'NONE', CAST(10 AS SMALLINT),
     N'Countries from LEGAL_AREA (SUBCLASS = 1). Small reference; truncate and reload.'),

    (N'DIM_PARTY_LOAD', N'USER',
     N'SICS.dbo.CNU_USER',           N'dbo.DIM_USER',
     'INCREMENTAL', 'CT_VERSION', CAST(20 AS SMALLINT),
     N'Users. Change Tracking. SCD Type 2 on name and org unit.'),

    (N'DIM_PARTY_LOAD', N'COMPANY',
     N'SICS.dbo.PARTY',              N'dbo.DIM_COMPANY',
     'INCREMENTAL', 'CT_VERSION', CAST(30 AS SMALLINT),
     N'Company / business partner (PARTY SUBCLASS = 4). Change Tracking.'),

    (N'DIM_PARTY_LOAD', N'BROKER',
     N'SICS.dbo.PARTY',              N'dbo.DIM_BROKER',
     'INCREMENTAL', 'CT_VERSION', CAST(40 AS SMALLINT),
     N'Brokers (PARTY filtered by business-partner category). Change Tracking.'),

    (N'DIM_PARTY_LOAD', N'CRESTA_ZONE',
     N'SICS.dbo.RISK_ZONE',          N'dbo.DIM_CRESTA_ZONE',
     'FULL', 'NONE', CAST(50 AS SMALLINT),
     N'CRESTA / risk zones from RISK_ZONE. Small reference; truncate and reload.'),

    (N'DIM_PARTY_LOAD', N'ORIGINAL_INSURED',
     N'SICS.dbo.PARTY',              N'dbo.DIM_ORIGINAL_INSURED',
     'INCREMENTAL', 'CT_VERSION', CAST(60 AS SMALLINT),
     N'Original insured parties (PARTY role filter — confirm population rule). Change Tracking.')
) AS v (JOB_NAME, TABLE_NAME, SOURCE_OBJECT, TARGET_OBJECT,
        LOAD_TYPE, WATERMARK_TYPE, LOAD_ORDER, DESCRIPTION)
     INNER JOIN etl.ETL_JOB AS j ON j.JOB_NAME = v.JOB_NAME
WHERE NOT EXISTS
(
    SELECT 1 FROM etl.ETL_JOB_TABLE AS t
    WHERE t.JOB_ID = j.JOB_ID AND t.TABLE_NAME = v.TABLE_NAME
);
GO
