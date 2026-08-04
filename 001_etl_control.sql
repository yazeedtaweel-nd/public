/* ============================================================
   Migration: 001_etl_control.sql
   ETL Control Layer — schema, five tables, one monitoring view.
   Target: existing Data Warehouse database (SaudiRe_DW or equiv.)
   Re-runnable. Applied once via scripts/Apply-Migrations.* + ledger.

   A job is one SSIS package. A package may load many tables;
   each table has its own watermark.
   ============================================================ */

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'etl')
    EXEC (N'CREATE SCHEMA etl AUTHORIZATION dbo;');
GO

/* ------------------------------------------------------------
   etl.ETL_JOB
   One row per SSIS package.
   ------------------------------------------------------------ */
IF OBJECT_ID(N'etl.ETL_JOB', N'U') IS NULL
BEGIN
    CREATE TABLE etl.ETL_JOB
    (
        JOB_ID          INT     IDENTITY(1,1)   NOT NULL,
        JOB_NAME        NVARCHAR(128)           NOT NULL,
        PACKAGE_NAME    NVARCHAR(260)               NULL,
        EXECUTION_ORDER SMALLINT                NOT NULL
            CONSTRAINT DF_ETL_JOB_EXEC_ORDER DEFAULT (100),
        IS_ENABLED      BIT                     NOT NULL
            CONSTRAINT DF_ETL_JOB_IS_ENABLED DEFAULT (1),
        DESCRIPTION     NVARCHAR(1000)              NULL,

        CONSTRAINT PK_ETL_JOB PRIMARY KEY CLUSTERED (JOB_ID),
        CONSTRAINT UQ_ETL_JOB_JOB_NAME UNIQUE (JOB_NAME)
    );
END
GO

/* ------------------------------------------------------------
   etl.ETL_JOB_TABLE
   One row per source/target table inside a package.
   Holds that table's load settings and its own watermark.
   ------------------------------------------------------------ */
IF OBJECT_ID(N'etl.ETL_JOB_TABLE', N'U') IS NULL
BEGIN
    CREATE TABLE etl.ETL_JOB_TABLE
    (
        JOB_TABLE_ID            INT     IDENTITY(1,1)   NOT NULL,
        JOB_ID                  INT                     NOT NULL,
        TABLE_NAME              NVARCHAR(128)           NOT NULL,
        SOURCE_OBJECT           NVARCHAR(256)               NULL,
        TARGET_OBJECT           NVARCHAR(256)               NULL,
        LOAD_TYPE               VARCHAR(20)             NOT NULL,
        WATERMARK_TYPE          VARCHAR(20)             NOT NULL
            CONSTRAINT DF_ETL_JOB_TABLE_WATERMARK_TYPE DEFAULT ('NONE'),
        /* Last successfully loaded high-water value for this table.
           NULL means never loaded, so the next run extracts everything. */
        WATERMARK_VALUE         NVARCHAR(100)               NULL,
        WATERMARK_UPDATED_DATE  DATETIME2(3)                NULL,
        LOAD_ORDER              SMALLINT                NOT NULL
            CONSTRAINT DF_ETL_JOB_TABLE_LOAD_ORDER     DEFAULT (100),
        IS_ENABLED              BIT                     NOT NULL
            CONSTRAINT DF_ETL_JOB_TABLE_IS_ENABLED     DEFAULT (1),
        DESCRIPTION             NVARCHAR(1000)              NULL,

        CONSTRAINT PK_ETL_JOB_TABLE PRIMARY KEY CLUSTERED (JOB_TABLE_ID),
        CONSTRAINT UQ_ETL_JOB_TABLE_JOB_NAME UNIQUE (JOB_ID, TABLE_NAME),
        CONSTRAINT FK_ETL_JOB_TABLE_JOB
            FOREIGN KEY (JOB_ID) REFERENCES etl.ETL_JOB (JOB_ID),
        CONSTRAINT CK_ETL_JOB_TABLE_LOAD_TYPE
            CHECK (LOAD_TYPE IN ('FULL', 'INCREMENTAL')),
        CONSTRAINT CK_ETL_JOB_TABLE_WATERMARK_TYPE
            CHECK (WATERMARK_TYPE IN ('NONE', 'CDC_LSN', 'CT_VERSION', 'DATETIME', 'ID')),
        CONSTRAINT CK_ETL_JOB_TABLE_INCREMENTAL_NEEDS_WATERMARK
            CHECK (LOAD_TYPE = 'FULL' OR WATERMARK_TYPE <> 'NONE')
    );

    CREATE INDEX IX_ETL_JOB_TABLE_JOB_ORDER
        ON etl.ETL_JOB_TABLE (JOB_ID, LOAD_ORDER, TABLE_NAME);
END
GO

/* ------------------------------------------------------------
   etl.ETL_JOB_EXECUTION
   One row per package run.
   ------------------------------------------------------------ */
IF OBJECT_ID(N'etl.ETL_JOB_EXECUTION', N'U') IS NULL
BEGIN
    CREATE TABLE etl.ETL_JOB_EXECUTION
    (
        EXECUTION_ID    BIGINT  IDENTITY(1,1)   NOT NULL,
        JOB_ID          INT                     NOT NULL,
        START_TIME      DATETIME2(3)            NOT NULL
            CONSTRAINT DF_ETL_JOB_EXECUTION_START_TIME  DEFAULT (SYSUTCDATETIME()),
        END_TIME        DATETIME2(3)                NULL,
        STATUS          VARCHAR(20)             NOT NULL
            CONSTRAINT DF_ETL_JOB_EXECUTION_STATUS      DEFAULT ('RUNNING'),
        ROWS_READ       BIGINT                      NULL,
        ROWS_INSERTED   BIGINT                      NULL,
        ROWS_UPDATED    BIGINT                      NULL,
        ROWS_REJECTED   BIGINT                      NULL,
        EXECUTED_BY     NVARCHAR(128)           NOT NULL
            CONSTRAINT DF_ETL_JOB_EXECUTION_EXECUTED_BY DEFAULT (SUSER_SNAME()),
        DURATION_SEC    AS DATEDIFF(SECOND, START_TIME, END_TIME),

        CONSTRAINT PK_ETL_JOB_EXECUTION PRIMARY KEY CLUSTERED (EXECUTION_ID),
        CONSTRAINT FK_ETL_JOB_EXECUTION_JOB
            FOREIGN KEY (JOB_ID) REFERENCES etl.ETL_JOB (JOB_ID),
        CONSTRAINT CK_ETL_JOB_EXECUTION_STATUS
            CHECK (STATUS IN ('RUNNING', 'SUCCEEDED', 'FAILED', 'CANCELLED'))
    );

    CREATE INDEX IX_ETL_JOB_EXECUTION_JOB_START
        ON etl.ETL_JOB_EXECUTION (JOB_ID, START_TIME DESC);
END
GO

/* ------------------------------------------------------------
   etl.ETL_ERROR_LOG
   Errors and rejected rows, always tied to one package execution.
   JOB_TABLE_ID is optional and identifies which table failed.
   ------------------------------------------------------------ */
IF OBJECT_ID(N'etl.ETL_ERROR_LOG', N'U') IS NULL
BEGIN
    CREATE TABLE etl.ETL_ERROR_LOG
    (
        ERROR_ID        BIGINT  IDENTITY(1,1)   NOT NULL,
        EXECUTION_ID    BIGINT                  NOT NULL,
        JOB_TABLE_ID    INT                         NULL,
        LOGGED_DATE     DATETIME2(3)            NOT NULL
            CONSTRAINT DF_ETL_ERROR_LOG_LOGGED_DATE DEFAULT (SYSUTCDATETIME()),
        SEVERITY        VARCHAR(10)             NOT NULL
            CONSTRAINT DF_ETL_ERROR_LOG_SEVERITY    DEFAULT ('ERROR'),
        TASK_NAME       NVARCHAR(256)               NULL,
        ERROR_MESSAGE   NVARCHAR(MAX)               NULL,
        SOURCE_KEY      NVARCHAR(200)               NULL,
        ROW_DATA        NVARCHAR(MAX)               NULL,

        CONSTRAINT PK_ETL_ERROR_LOG PRIMARY KEY CLUSTERED (ERROR_ID),
        CONSTRAINT FK_ETL_ERROR_LOG_EXECUTION
            FOREIGN KEY (EXECUTION_ID) REFERENCES etl.ETL_JOB_EXECUTION (EXECUTION_ID),
        CONSTRAINT FK_ETL_ERROR_LOG_JOB_TABLE
            FOREIGN KEY (JOB_TABLE_ID) REFERENCES etl.ETL_JOB_TABLE (JOB_TABLE_ID),
        CONSTRAINT CK_ETL_ERROR_LOG_SEVERITY
            CHECK (SEVERITY IN ('ERROR', 'WARNING'))
    );

    CREATE INDEX IX_ETL_ERROR_LOG_EXECUTION
        ON etl.ETL_ERROR_LOG (EXECUTION_ID);
END
GO

/* ------------------------------------------------------------
   etl.ETL_PARAMETER
   Configuration key/value pairs.
   JOB_ID NULL means the value is global.
   ------------------------------------------------------------ */
IF OBJECT_ID(N'etl.ETL_PARAMETER', N'U') IS NULL
BEGIN
    CREATE TABLE etl.ETL_PARAMETER
    (
        PARAMETER_ID    INT     IDENTITY(1,1)   NOT NULL,
        JOB_ID          INT                         NULL,
        PARAM_NAME      NVARCHAR(128)           NOT NULL,
        PARAM_VALUE     NVARCHAR(1000)              NULL,
        DESCRIPTION     NVARCHAR(1000)              NULL,

        CONSTRAINT PK_ETL_PARAMETER PRIMARY KEY CLUSTERED (PARAMETER_ID),
        CONSTRAINT FK_ETL_PARAMETER_JOB
            FOREIGN KEY (JOB_ID) REFERENCES etl.ETL_JOB (JOB_ID)
    );

    /* SQL Server treats NULLs as equal in a unique index, so this allows
       exactly one global row and one per-job override for each name. */
    CREATE UNIQUE INDEX UX_ETL_PARAMETER_JOB_NAME
        ON etl.ETL_PARAMETER (JOB_ID, PARAM_NAME);
END
GO

/* ------------------------------------------------------------
   etl.VW_JOB_TABLE_STATUS
   One row per table: current watermark and how the latest package
   run went. The daily monitoring query.
   ------------------------------------------------------------ */
CREATE OR ALTER VIEW etl.VW_JOB_TABLE_STATUS
AS
SELECT  j.JOB_ID,
        j.JOB_NAME,
        j.PACKAGE_NAME,
        j.IS_ENABLED            AS JOB_IS_ENABLED,
        t.JOB_TABLE_ID,
        t.TABLE_NAME,
        t.SOURCE_OBJECT,
        t.TARGET_OBJECT,
        t.LOAD_TYPE,
        t.WATERMARK_TYPE,
        t.WATERMARK_VALUE       AS CURRENT_WATERMARK,
        t.WATERMARK_UPDATED_DATE,
        t.LOAD_ORDER,
        t.IS_ENABLED            AS TABLE_IS_ENABLED,
        e.EXECUTION_ID          AS LAST_EXECUTION_ID,
        e.STATUS                AS LAST_PACKAGE_STATUS,
        e.START_TIME            AS LAST_PACKAGE_START_TIME,
        e.DURATION_SEC          AS LAST_PACKAGE_DURATION_SEC,
        e.ROWS_INSERTED         AS LAST_PACKAGE_ROWS_INSERTED,
        e.ROWS_UPDATED          AS LAST_PACKAGE_ROWS_UPDATED,
        e.ROWS_REJECTED         AS LAST_PACKAGE_ROWS_REJECTED,
        DATEDIFF(MINUTE, e.START_TIME, SYSUTCDATETIME()) AS MINUTES_SINCE_LAST_START
FROM    etl.ETL_JOB AS j
        INNER JOIN etl.ETL_JOB_TABLE AS t
            ON t.JOB_ID = j.JOB_ID
        OUTER APPLY
        (
            SELECT  TOP (1) x.*
            FROM    etl.ETL_JOB_EXECUTION AS x
            WHERE   x.JOB_ID = j.JOB_ID
            ORDER BY x.START_TIME DESC, x.EXECUTION_ID DESC
        ) AS e;
GO
