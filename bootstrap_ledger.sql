/* ============================================================
   Bootstrap: etl schema + SCHEMA_MIGRATION ledger
   Run by Apply-Migrations before numbered scripts.
   Idempotent.
   ============================================================ */

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'etl')
    EXEC (N'CREATE SCHEMA etl AUTHORIZATION dbo;');
GO

IF OBJECT_ID(N'etl.SCHEMA_MIGRATION', N'U') IS NULL
BEGIN
    CREATE TABLE etl.SCHEMA_MIGRATION
    (
        MIGRATION_ID   INT IDENTITY(1, 1) NOT NULL,
        SCRIPT_NAME    NVARCHAR(260)      NOT NULL,
        APPLIED_DATE   DATETIME2(3)       NOT NULL
            CONSTRAINT DF_SCHEMA_MIGRATION_APPLIED_DATE DEFAULT (SYSUTCDATETIME()),
        APPLIED_BY     NVARCHAR(128)      NOT NULL
            CONSTRAINT DF_SCHEMA_MIGRATION_APPLIED_BY   DEFAULT (SUSER_SNAME()),

        CONSTRAINT PK_SCHEMA_MIGRATION PRIMARY KEY CLUSTERED (MIGRATION_ID),
        CONSTRAINT UQ_SCHEMA_MIGRATION_SCRIPT UNIQUE (SCRIPT_NAME)
    );
END
GO
