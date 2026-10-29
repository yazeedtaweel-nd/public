/*
    SQL Server data comparison framework
    ------------------------------------
    Public procedures:
        dbo.CompareTables
        dbo.FindDuplicates
        dbo.CompareTableCounts

    History schema (optional Python --persist):
        compare.Run
        compare.RunTable
        compare.RunDetail
        compare.RunDuplicate
        compare.RunSchema

    Supporting objects:
        dbo.SplitCsv
        dbo.Compare_TypeFamily
        dbo.Compare_TypesAreCompatible
        dbo.Compare_BuildFilter
        dbo.Compare_ResolveTable

    Requirements: SQL Server 2016 SP1 or later
    (CREATE OR ALTER, HASHBYTES over varbinary(max), DROP TABLE IF EXISTS).

    Deploy by running this script in a utility database. The procedures compare
    tables or views in other databases through three-part names; they do not
    need to live in DWH or DWH2. Optional @SourceServer / @TargetServer use a
    SQL Server linked server and Windows authentication when the object is on
    another instance.

    Example:
        EXEC dbo.CompareTables
            @SourceDatabase = N'DWH',
            @TargetDatabase = N'DWH2',
            @SchemaName     = N'dbo',
            @TableName      = N'CUSTOMER',
            @KeyColumns     = N'CUSTOMER_ID';
*/

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER FUNCTION dbo.SplitCsv (@Csv nvarchar(max))
RETURNS @Items TABLE (
    Ordinal int NOT NULL,
    Item nvarchar(4000) NOT NULL
)
AS
BEGIN
    IF @Csv IS NULL
        RETURN;

    DECLARE @Work nvarchar(max) = REPLACE(REPLACE(REPLACE(@Csv, CHAR(13), N''), CHAR(10), N''), CHAR(9), N'');
    DECLARE @Pos int;
    DECLARE @Ordinal int = 0;
    DECLARE @Item nvarchar(4000);

    WHILE @Work IS NOT NULL AND LEN(@Work) > 0
    BEGIN
        SET @Pos = CHARINDEX(N',', @Work);

        IF @Pos = 0
        BEGIN
            SET @Item = LTRIM(RTRIM(@Work));
            SET @Work = N'';
        END
        ELSE
        BEGIN
            SET @Item = LTRIM(RTRIM(SUBSTRING(@Work, 1, @Pos - 1)));
            /* Large length avoids LEN() dropping trailing spaces. */
            SET @Work = SUBSTRING(@Work, @Pos + 1, 400000);
        END;

        IF LEFT(@Item, 1) = N'[' AND RIGHT(@Item, 1) = N']' AND LEN(@Item) >= 2
            SET @Item = REPLACE(SUBSTRING(@Item, 2, LEN(@Item) - 2), N']]', N']');

        SET @Ordinal += 1;
        INSERT INTO @Items (Ordinal, Item)
        VALUES (@Ordinal, @Item);
    END;

    RETURN;
END;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER FUNCTION dbo.Compare_GlobToLike (@Glob nvarchar(4000))
RETURNS nvarchar(4000)
WITH SCHEMABINDING
AS
BEGIN
    IF @Glob IS NULL
        RETURN NULL;

    DECLARE @Out nvarchar(4000) = N'';
    DECLARE @Pos int = 1;
    DECLARE @Len int = LEN(@Glob);
    DECLARE @Ch nchar(1);

    WHILE @Pos <= @Len
    BEGIN
        SET @Ch = SUBSTRING(@Glob, @Pos, 1);

        IF @Ch = N'*'
            SET @Out += N'%';
        ELSE IF @Ch = N'?'
            SET @Out += N'_';
        ELSE IF @Ch = N'%'
            SET @Out += N'[%]';
        ELSE IF @Ch = N'_'
            SET @Out += N'[_]';
        ELSE IF @Ch = N'['
            SET @Out += N'[[]';
        ELSE
            SET @Out += @Ch;

        SET @Pos += 1;
    END;

    RETURN @Out;
END;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER FUNCTION dbo.Compare_TypeFamily (@BaseType sysname)
RETURNS varchar(30)
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE
        WHEN @BaseType IN (N'tinyint', N'smallint', N'int', N'bigint') THEN 'integer'
        WHEN @BaseType IN (N'decimal', N'numeric') THEN 'decimal'
        WHEN @BaseType IN (N'money', N'smallmoney') THEN 'money'
        WHEN @BaseType IN (N'char', N'varchar', N'nchar', N'nvarchar', N'text', N'ntext') THEN 'string'
        WHEN @BaseType IN (
            N'bit', N'float', N'real', N'date', N'time', N'datetime', N'smalldatetime',
            N'datetime2', N'datetimeoffset', N'uniqueidentifier', N'binary', N'varbinary',
            N'image', N'timestamp', N'xml'
        ) THEN CONVERT(varchar(30), @BaseType)
        ELSE NULL
    END;
END;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER FUNCTION dbo.Compare_TypesAreCompatible (
    @Family varchar(30),
    @BaseType sysname,
    @MaxLength int,
    @Scale int,
    @OtherFamily varchar(30),
    @OtherBaseType sysname,
    @OtherMaxLength int,
    @OtherScale int
)
RETURNS bit
WITH SCHEMABINDING
AS
BEGIN
    IF @Family IS NULL OR @OtherFamily IS NULL OR @Family <> @OtherFamily
        RETURN 0;

    /* Same value, different storage width or character type. */
    IF @Family IN ('integer', 'decimal', 'money', 'string')
        RETURN 1;

    IF @BaseType IN (N'datetime2', N'time', N'datetimeoffset')
       AND ISNULL(@Scale, -1) <> ISNULL(@OtherScale, -1)
        RETURN 0;

    IF @BaseType IN (N'binary', N'varbinary')
       AND ISNULL(@MaxLength, -2) <> ISNULL(@OtherMaxLength, -2)
        RETURN 0;

    RETURN 1;
END;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.Compare_BuildFilter
    @Filter nvarchar(max),
    @Alias sysname = NULL,
    @WhereSql nvarchar(max) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @WhereSql = NULL;

    DECLARE @Work nvarchar(max) = LTRIM(RTRIM(@Filter));
    IF @Work IS NULL OR @Work = N''
        RETURN;

    IF @Alias IS NOT NULL
       AND @Alias NOT IN (N's', N't', N'src', N'tgt')
        THROW 50001, N'@Alias must be s, t, src, tgt, or NULL.', 1;

    IF CHARINDEX(N';', @Work) > 0
        THROW 50001, N'@Filter cannot contain a statement separator.', 1;

    IF CHARINDEX(N'--', @Work) > 0
        OR CHARINDEX(N'/*', @Work) > 0
        OR CHARINDEX(N'*/', @Work) > 0
        THROW 50001, N'@Filter cannot contain comments.', 1;

    IF CHARINDEX(N'(', @Work) > 0 OR CHARINDEX(N')', @Work) > 0
        THROW 50001, N'@Filter does not support parentheses. Combine predicates with AND.', 1;

    IF OBJECT_ID(N'tempdb..#AllowedFilterCols') IS NULL
        THROW 50001, N'@Filter validation requires #AllowedFilterCols.', 1;

    DECLARE @Pos int = 1;
    DECLARE @Len int = LEN(@Work);
    DECLARE @Sql nvarchar(max) = N'';
    DECLARE @NeedAnd bit = 0;
    DECLARE @Ch nchar(1);
    DECLARE @Col nvarchar(4000);
    DECLARE @Resolved sysname;
    DECLARE @Start int;
    DECLARE @Op nvarchar(16);
    DECLARE @Literal nvarchar(max);
    DECLARE @Prefix nvarchar(16) = CASE WHEN @Alias IS NULL THEN N'' ELSE @Alias + N'.' END;
    DECLARE @Word nvarchar(20);
    DECLARE @Unknown nvarchar(400);

    WHILE @Pos <= @Len
    BEGIN
        WHILE @Pos <= @Len AND SUBSTRING(@Work, @Pos, 1) LIKE N'[ ' + CHAR(9) + CHAR(13) + CHAR(10) + N']'
            SET @Pos += 1;

        IF @Pos > @Len
            BREAK;

        IF @NeedAnd = 1
        BEGIN
            IF @Pos + 2 > @Len OR UPPER(SUBSTRING(@Work, @Pos, 3)) <> N'AND'
                THROW 50001, N'@Filter predicates must be joined with AND.', 1;

            SET @Pos += 3;
            IF @Pos <= @Len AND SUBSTRING(@Work, @Pos, 1) LIKE N'[A-Za-z0-9_@#$]'
                THROW 50001, N'@Filter predicates must be joined with AND.', 1;

            SET @NeedAnd = 0;
            CONTINUE;
        END;

        SET @Ch = SUBSTRING(@Work, @Pos, 1);
        SET @Col = NULL;

        IF @Ch = N'['
        BEGIN
            SET @Pos += 1;
            SET @Col = N'';
            WHILE @Pos <= @Len
            BEGIN
                IF SUBSTRING(@Work, @Pos, 1) = N']'
                BEGIN
                    IF @Pos < @Len AND SUBSTRING(@Work, @Pos + 1, 1) = N']'
                    BEGIN
                        SET @Col += N']';
                        SET @Pos += 2;
                    END
                    ELSE
                    BEGIN
                        SET @Pos += 1;
                        BREAK;
                    END;
                END
                ELSE
                BEGIN
                    SET @Col += SUBSTRING(@Work, @Pos, 1);
                    SET @Pos += 1;
                END;
            END;
        END
        ELSE IF @Ch LIKE N'[A-Za-z_@#]'
        BEGIN
            SET @Start = @Pos;
            WHILE @Pos <= @Len AND SUBSTRING(@Work, @Pos, 1) LIKE N'[A-Za-z0-9_@#$]'
                SET @Pos += 1;
            SET @Col = SUBSTRING(@Work, @Start, @Pos - @Start);
        END
        ELSE
            THROW 50001, N'@Filter must start each predicate with a column name.', 1;

        IF @Col IS NULL OR @Col = N''
            THROW 50001, N'@Filter contains an empty column name.', 1;

        SET @Resolved = NULL;
        SELECT @Resolved = c.ColumnName
        FROM #AllowedFilterCols AS c
        WHERE c.ColumnName = @Col;

        IF @Resolved IS NULL
            SELECT @Resolved = c.ColumnName
            FROM #AllowedFilterCols AS c
            WHERE LOWER(c.ColumnName) = LOWER(@Col);

        IF @Resolved IS NULL
        BEGIN
            SET @Unknown = N'Filter column ''' + REPLACE(@Col, N'''', N'''''')
                + N''' does not exist on both tables.';
            THROW 50001, @Unknown, 1;
        END;

        WHILE @Pos <= @Len AND SUBSTRING(@Work, @Pos, 1) LIKE N'[ ' + CHAR(9) + CHAR(13) + CHAR(10) + N']'
            SET @Pos += 1;

        IF @Pos > @Len
            THROW 50001, N'@Filter is missing an operator after a column name.', 1;

        SET @Op = NULL;
        SET @Word = UPPER(SUBSTRING(@Work, @Pos, 4));
        IF @Word = N'LIKE' AND (
                @Pos + 4 > @Len
                OR SUBSTRING(@Work, @Pos + 4, 1) NOT LIKE N'[A-Za-z0-9_@#$]'
            )
        BEGIN
            SET @Op = N'LIKE';
            SET @Pos += 4;
        END
        ELSE IF UPPER(SUBSTRING(@Work, @Pos, 2)) = N'IS'
            AND (
                @Pos + 2 > @Len
                OR SUBSTRING(@Work, @Pos + 2, 1) NOT LIKE N'[A-Za-z0-9_@#$]'
            )
        BEGIN
            SET @Pos += 2;
            WHILE @Pos <= @Len AND SUBSTRING(@Work, @Pos, 1) LIKE N'[ ' + CHAR(9) + CHAR(13) + CHAR(10) + N']'
                SET @Pos += 1;

            IF @Pos + 2 <= @Len
               AND UPPER(SUBSTRING(@Work, @Pos, 3)) = N'NOT'
               AND (
                    @Pos + 3 > @Len
                    OR SUBSTRING(@Work, @Pos + 3, 1) NOT LIKE N'[A-Za-z0-9_@#$]'
               )
            BEGIN
                SET @Pos += 3;
                WHILE @Pos <= @Len AND SUBSTRING(@Work, @Pos, 1) LIKE N'[ ' + CHAR(9) + CHAR(13) + CHAR(10) + N']'
                    SET @Pos += 1;
                IF @Pos + 3 > @Len
                   OR UPPER(SUBSTRING(@Work, @Pos, 4)) <> N'NULL'
                   OR (
                        @Pos + 4 <= @Len
                        AND SUBSTRING(@Work, @Pos + 4, 1) LIKE N'[A-Za-z0-9_@#$]'
                   )
                    THROW 50001, N'@Filter IS NOT must be followed by NULL.', 1;
                SET @Pos += 4;
                SET @Op = N'IS NOT NULL';
            END
            ELSE IF @Pos + 3 <= @Len
                AND UPPER(SUBSTRING(@Work, @Pos, 4)) = N'NULL'
                AND (
                    @Pos + 4 > @Len
                    OR SUBSTRING(@Work, @Pos + 4, 1) NOT LIKE N'[A-Za-z0-9_@#$]'
                )
            BEGIN
                SET @Pos += 4;
                SET @Op = N'IS NULL';
            END
            ELSE
                THROW 50001, N'@Filter IS must be followed by NULL or NOT NULL.', 1;
        END
        ELSE IF SUBSTRING(@Work, @Pos, 2) IN (N'<>', N'<=', N'>=', N'!=')
        BEGIN
            SET @Op = SUBSTRING(@Work, @Pos, 2);
            SET @Pos += 2;
        END
        ELSE IF SUBSTRING(@Work, @Pos, 1) IN (N'=', N'<', N'>')
        BEGIN
            SET @Op = SUBSTRING(@Work, @Pos, 1);
            SET @Pos += 1;
        END
        ELSE
            THROW 50001, N'@Filter supports =, <>, !=, <, >, <=, >=, LIKE, IS NULL, and IS NOT NULL.', 1;

        SET @Literal = NULL;
        IF @Op NOT IN (N'IS NULL', N'IS NOT NULL')
        BEGIN
            WHILE @Pos <= @Len AND SUBSTRING(@Work, @Pos, 1) LIKE N'[ ' + CHAR(9) + CHAR(13) + CHAR(10) + N']'
                SET @Pos += 1;

            IF @Pos > @Len
                THROW 50001, N'@Filter is missing a value after an operator.', 1;

            IF UPPER(SUBSTRING(@Work, @Pos, 4)) = N'NULL'
               AND (
                    @Pos + 4 > @Len
                    OR SUBSTRING(@Work, @Pos + 4, 1) NOT LIKE N'[A-Za-z0-9_@#$]'
               )
            BEGIN
                SET @Literal = N'NULL';
                SET @Pos += 4;
            END
            ELSE IF SUBSTRING(@Work, @Pos, 1) = N''''
                OR (
                    UPPER(SUBSTRING(@Work, @Pos, 1)) = N'N'
                    AND @Pos < @Len
                    AND SUBSTRING(@Work, @Pos + 1, 1) = N''''
                )
            BEGIN
                SET @Literal = N'';
                IF UPPER(SUBSTRING(@Work, @Pos, 1)) = N'N'
                BEGIN
                    SET @Literal = N'N';
                    SET @Pos += 1;
                END;
                SET @Literal += N'''';
                SET @Pos += 1;
                WHILE @Pos <= @Len
                BEGIN
                    IF SUBSTRING(@Work, @Pos, 1) = N''''
                    BEGIN
                        IF @Pos < @Len AND SUBSTRING(@Work, @Pos + 1, 1) = N''''
                        BEGIN
                            SET @Literal += N'''''';
                            SET @Pos += 2;
                        END
                        ELSE
                        BEGIN
                            SET @Literal += N'''';
                            SET @Pos += 1;
                            BREAK;
                        END;
                    END
                    ELSE
                    BEGIN
                        SET @Literal += SUBSTRING(@Work, @Pos, 1);
                        SET @Pos += 1;
                    END;
                END;
                IF RIGHT(@Literal, 1) <> N''''
                    THROW 50001, N'@Filter has an unterminated string literal.', 1;
            END
            ELSE IF SUBSTRING(@Work, @Pos, 1) LIKE N'[0-9\-]'
            BEGIN
                SET @Start = @Pos;
                IF SUBSTRING(@Work, @Pos, 1) = N'-'
                    SET @Pos += 1;
                IF @Pos > @Len OR SUBSTRING(@Work, @Pos, 1) NOT LIKE N'[0-9]'
                    THROW 50001, N'@Filter numeric literals must start with a digit.', 1;
                WHILE @Pos <= @Len AND SUBSTRING(@Work, @Pos, 1) LIKE N'[0-9]'
                    SET @Pos += 1;
                IF @Pos <= @Len AND SUBSTRING(@Work, @Pos, 1) = N'.'
                BEGIN
                    SET @Pos += 1;
                    IF @Pos > @Len OR SUBSTRING(@Work, @Pos, 1) NOT LIKE N'[0-9]'
                        THROW 50001, N'@Filter numeric literals need a digit after the decimal point.', 1;
                    WHILE @Pos <= @Len AND SUBSTRING(@Work, @Pos, 1) LIKE N'[0-9]'
                        SET @Pos += 1;
                END;
                SET @Literal = SUBSTRING(@Work, @Start, @Pos - @Start);
            END
            ELSE
                THROW 50001, N'@Filter values must be a quoted string, a number, or NULL.', 1;
        END;

        IF @Sql <> N''
            SET @Sql += N' AND ';

        IF @Op IN (N'IS NULL', N'IS NOT NULL')
            SET @Sql += @Prefix + QUOTENAME(@Resolved) + N' ' + @Op;
        ELSE
            SET @Sql += @Prefix + QUOTENAME(@Resolved) + N' ' + @Op + N' ' + @Literal;

        SET @NeedAnd = 1;
    END;

    IF @Sql = N''
        THROW 50001, N'@Filter is not a valid predicate.', 1;

    IF @NeedAnd = 0
        THROW 50001, N'@Filter has a trailing AND.', 1;

    SET @WhereSql = @Sql;
END;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.Compare_ResolveTable
    @Side sysname,
    @DatabaseName sysname,
    @SchemaName sysname,
    @TableName sysname,
    @ServerName sysname = NULL,
    @ResolvedDatabase sysname OUTPUT,
    @ResolvedSchema sysname OUTPUT,
    @ResolvedTable sysname OUTPUT,
    @ResolvedServer sysname = NULL OUTPUT,
    @ResolvedObject nvarchar(1040) = NULL OUTPUT,
    @CatalogPrefix nvarchar(520) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Message nvarchar(2048);
    DECLARE @Sql nvarchar(max);
    DECLARE @Location nvarchar(600);
    DECLARE @IsLocal bit = 1;
    DECLARE @IsDataAccess bit = 1;
    DECLARE @Product sysname;
    DECLARE @Provider sysname;
    DECLARE @UsesSelf bit;
    DECLARE @LoginType char(1);

    SET @ResolvedServer = NULL;
    SET @ResolvedDatabase = NULL;
    SET @ResolvedSchema = NULL;
    SET @ResolvedTable = NULL;
    SET @ResolvedObject = NULL;
    SET @CatalogPrefix = NULL;
    SET @Side = ISNULL(NULLIF(LTRIM(RTRIM(@Side)), N''), N'Referenced');
    SET @ServerName = NULLIF(LTRIM(RTRIM(@ServerName)), N'');
    IF @ServerName IS NOT NULL
       AND LEFT(@ServerName, 1) = N'['
       AND RIGHT(@ServerName, 1) = N']'
       AND LEN(@ServerName) >= 2
        SET @ServerName = REPLACE(SUBSTRING(@ServerName, 2, LEN(@ServerName) - 2), N']]', N']');
    SET @DatabaseName = LTRIM(RTRIM(@DatabaseName));
    SET @SchemaName = LTRIM(RTRIM(@SchemaName));
    SET @TableName = LTRIM(RTRIM(@TableName));

    IF @DatabaseName IS NULL OR @DatabaseName = N''
    BEGIN
        SET @Message = @Side + N' database is required.';
        THROW 50001, @Message, 1;
    END;

    IF @SchemaName IS NULL OR @SchemaName = N''
    BEGIN
        SET @Message = @Side + N' schema is required.';
        THROW 50001, @Message, 1;
    END;

    IF @TableName IS NULL OR @TableName = N''
    BEGIN
        SET @Message = @Side + N' table is required.';
        THROW 50001, @Message, 1;
    END;

    IF @ServerName IS NOT NULL
    BEGIN
        SELECT
            @ResolvedServer = name,
            @IsLocal = CASE WHEN server_id = 0 THEN 1 ELSE 0 END,
            @IsDataAccess = is_data_access_enabled,
            @Product = LTRIM(RTRIM(product)),
            @Provider = LTRIM(RTRIM(provider))
        FROM sys.servers
        WHERE name = @ServerName;

        IF @ResolvedServer IS NULL
        BEGIN
            SET @Message = @Side + N' server ''' + REPLACE(@ServerName, N'''', N'''''')
                + N''' is not a local or linked server.';
            THROW 50001, @Message, 1;
        END;

        IF @IsLocal = 1
            SET @ResolvedServer = NULL;
        ELSE
        BEGIN
            IF NOT (
                @Product = N'SQL Server'
                OR @Provider IN (N'SQLOLEDB', N'SQLNCLI', N'SQLNCLI10', N'SQLNCLI11', N'MSOLEDBSQL', N'MSOLEDBSQL19')
                OR @Provider LIKE N'SQLNCLI%'
                OR @Provider LIKE N'MSOLEDBSQL%'
            )
            BEGIN
                SET @Message = @Side + N' linked server ''' + REPLACE(@ServerName, N'''', N'''''')
                    + N''' must be a SQL Server linked server.';
                THROW 50001, @Message, 1;
            END;

            IF @IsDataAccess = 0
            BEGIN
                SET @Message = @Side + N' linked server ''' + REPLACE(@ServerName, N'''', N'''''')
                    + N''' does not have data access enabled.';
                THROW 50001, @Message, 1;
            END;

            SELECT @LoginType = type
            FROM sys.server_principals
            WHERE principal_id = SUSER_ID();

            IF @LoginType NOT IN (N'U', N'G')
            BEGIN
                SET @Message = N'Cross-server comparison requires a Windows login. SQL Server Authentication is not supported.';
                THROW 50001, @Message, 1;
            END;

            SELECT TOP (1)
                @UsesSelf = ll.uses_self_credential
            FROM sys.servers AS s
            INNER JOIN sys.linked_logins AS ll
                ON ll.server_id = s.server_id
            WHERE s.name = @ResolvedServer
              AND (ll.local_principal_id = SUSER_ID() OR ll.local_principal_id = 0)
            ORDER BY CASE WHEN ll.local_principal_id = SUSER_ID() THEN 0 ELSE 1 END;

            IF @UsesSelf IS NULL OR @UsesSelf <> 1
            BEGIN
                SET @Message = @Side + N' linked server ''' + REPLACE(@ServerName, N'''', N'''''')
                    + N''' must use Windows authentication (sp_addlinkedsrvlogin @useself = ''true'').';
                THROW 50001, @Message, 1;
            END;
        END;
    END;

    IF @ResolvedServer IS NULL
    BEGIN
        SELECT @ResolvedDatabase = name
        FROM sys.databases
        WHERE name = @DatabaseName;
    END
    ELSE
    BEGIN
        SET @Sql = N'
            SELECT @DbOut = name
            FROM ' + QUOTENAME(@ResolvedServer) + N'.master.sys.databases
            WHERE name = @DatabaseName;';

        BEGIN TRY
            EXEC sys.sp_executesql
                @Sql,
                N'@DatabaseName sysname, @DbOut sysname OUTPUT',
                @DatabaseName = @DatabaseName,
                @DbOut = @ResolvedDatabase OUTPUT;
        END TRY
        BEGIN CATCH
            SET @Message = @Side + N' catalog on server ''' + REPLACE(@ResolvedServer, N'''', N'''''')
                + N''' could not be read. ' + ERROR_MESSAGE();
            IF LEN(@Message) > 2048
                SET @Message = LEFT(@Message, 2045) + N'...';
            THROW 50001, @Message, 1;
        END CATCH;
    END;

    IF @ResolvedDatabase IS NULL
    BEGIN
        SET @Message = @Side + N' database ''' + REPLACE(@DatabaseName, N'''', N'''''') + N''' does not exist';
        IF @ResolvedServer IS NOT NULL
            SET @Message += N' on server ''' + REPLACE(@ResolvedServer, N'''', N'''''') + N'''';
        SET @Message += N'.';
        THROW 50001, @Message, 1;
    END;

    SET @CatalogPrefix = CASE
        WHEN @ResolvedServer IS NULL THEN QUOTENAME(@ResolvedDatabase) + N'.'
        ELSE QUOTENAME(@ResolvedServer) + N'.' + QUOTENAME(@ResolvedDatabase) + N'.'
    END;

    SET @Location = CASE
        WHEN @ResolvedServer IS NULL THEN QUOTENAME(@ResolvedDatabase)
        ELSE QUOTENAME(@ResolvedServer) + N'.' + QUOTENAME(@ResolvedDatabase)
    END;

    SET @Sql = N'
        SELECT @SchemaOut = s.name
        FROM ' + @CatalogPrefix + N'sys.schemas AS s
        WHERE s.name = @SchemaName;';

    BEGIN TRY
        EXEC sys.sp_executesql
            @Sql,
            N'@SchemaName sysname, @SchemaOut sysname OUTPUT',
            @SchemaName = @SchemaName,
            @SchemaOut = @ResolvedSchema OUTPUT;
    END TRY
    BEGIN CATCH
        IF @ResolvedServer IS NULL
            THROW;

        SET @Message = @Side + N' catalog on server ''' + REPLACE(@ResolvedServer, N'''', N'''''')
            + N''' could not be read. ' + ERROR_MESSAGE();
        IF LEN(@Message) > 2048
            SET @Message = LEFT(@Message, 2045) + N'...';
        THROW 50001, @Message, 1;
    END CATCH;

    IF @ResolvedSchema IS NULL
    BEGIN
        SET @Message = @Side + N' schema ''' + REPLACE(@SchemaName, N'''', N'''''')
            + N''' does not exist in ' + @Location + N'.';
        THROW 50001, @Message, 1;
    END;

    SET @Sql = N'
        SELECT @TableOut = t.name
        FROM ' + @CatalogPrefix + N'sys.objects AS t
        INNER JOIN ' + @CatalogPrefix + N'sys.schemas AS s
            ON s.schema_id = t.schema_id
        WHERE s.name = @SchemaName
          AND t.name = @TableName
          AND t.type IN (N''U'', N''V'');';

    BEGIN TRY
        EXEC sys.sp_executesql
            @Sql,
            N'@SchemaName sysname, @TableName sysname, @TableOut sysname OUTPUT',
            @SchemaName = @SchemaName,
            @TableName = @TableName,
            @TableOut = @ResolvedTable OUTPUT;
    END TRY
    BEGIN CATCH
        IF @ResolvedServer IS NULL
            THROW;

        SET @Message = @Side + N' catalog on server ''' + REPLACE(@ResolvedServer, N'''', N'''''')
            + N''' could not be read. ' + ERROR_MESSAGE();
        IF LEN(@Message) > 2048
            SET @Message = LEFT(@Message, 2045) + N'...';
        THROW 50001, @Message, 1;
    END CATCH;

    IF @ResolvedTable IS NULL
    BEGIN
        SET @Message = @Side + N' table ''' + REPLACE(@TableName, N'''', N'''''')
            + N''' does not exist in schema ''' + REPLACE(@ResolvedSchema, N'''', N'''''')
            + N''' of ' + @Location + N'.';
        THROW 50001, @Message, 1;
    END;

    SET @ResolvedObject = @CatalogPrefix + QUOTENAME(@ResolvedSchema) + N'.' + QUOTENAME(@ResolvedTable);
END;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.CompareTableCounts
    @SourceDatabase sysname,
    @TargetDatabase sysname,
    @SchemaName sysname = N'dbo',
    @TableName sysname,
    @SourceServer sysname = NULL,
    @TargetServer sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SourceDb sysname;
    DECLARE @SourceSchema sysname;
    DECLARE @SourceTable sysname;
    DECLARE @SourceObject nvarchar(1040);
    DECLARE @TargetDb sysname;
    DECLARE @TargetSchema sysname;
    DECLARE @TargetTable sysname;
    DECLARE @TargetObject nvarchar(1040);
    DECLARE @Sql nvarchar(max);

    EXEC dbo.Compare_ResolveTable
        @Side = N'Source',
        @DatabaseName = @SourceDatabase,
        @SchemaName = @SchemaName,
        @TableName = @TableName,
        @ServerName = @SourceServer,
        @ResolvedDatabase = @SourceDb OUTPUT,
        @ResolvedSchema = @SourceSchema OUTPUT,
        @ResolvedTable = @SourceTable OUTPUT,
        @ResolvedObject = @SourceObject OUTPUT;

    EXEC dbo.Compare_ResolveTable
        @Side = N'Target',
        @DatabaseName = @TargetDatabase,
        @SchemaName = @SchemaName,
        @TableName = @TableName,
        @ServerName = @TargetServer,
        @ResolvedDatabase = @TargetDb OUTPUT,
        @ResolvedSchema = @TargetSchema OUTPUT,
        @ResolvedTable = @TargetTable OUTPUT,
        @ResolvedObject = @TargetObject OUTPUT;

    SET @Sql = N'
        DECLARE @SourceRowCount bigint;
        DECLARE @TargetRowCount bigint;

        SELECT @SourceRowCount = COUNT_BIG(*)
        FROM ' + @SourceObject + N';

        SELECT @TargetRowCount = COUNT_BIG(*)
        FROM ' + @TargetObject + N';

        SELECT
            @TableName AS [Table],
            @SourceRowCount AS SourceRowCount,
            @TargetRowCount AS TargetRowCount,
            @SourceRowCount - @TargetRowCount AS CountDifference;';

    EXEC sys.sp_executesql
        @Sql,
        N'@TableName sysname',
        @TableName = @SourceTable;
END;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.FindDuplicates
    @DatabaseName sysname,
    @SchemaName sysname = N'dbo',
    @TableName sysname,
    @KeyColumns nvarchar(max),
    @ServerName sysname = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @ResolvedDb sysname;
    DECLARE @ResolvedSchema sysname;
    DECLARE @ResolvedTable sysname;
    DECLARE @Object nvarchar(1040);
    DECLARE @CatalogPrefix nvarchar(520);
    DECLARE @Message nvarchar(2048);
    DECLARE @Sql nvarchar(max);
    DECLARE @GroupBy nvarchar(max) = N'';
    DECLARE @KeyDisplay nvarchar(max) = N'';
    DECLARE @Ordinal int;
    DECLARE @Item nvarchar(4000);
    DECLARE @ResolvedName sysname;
    DECLARE @BaseType sysname;
    DECLARE @Family varchar(30);

    IF @KeyColumns IS NULL OR LTRIM(RTRIM(@KeyColumns)) = N''
        THROW 50001, N'At least one key column is required.', 1;

    EXEC dbo.Compare_ResolveTable
        @Side = N'Referenced',
        @DatabaseName = @DatabaseName,
        @SchemaName = @SchemaName,
        @TableName = @TableName,
        @ServerName = @ServerName,
        @ResolvedDatabase = @ResolvedDb OUTPUT,
        @ResolvedSchema = @ResolvedSchema OUTPUT,
        @ResolvedTable = @ResolvedTable OUTPUT,
        @ResolvedObject = @Object OUTPUT,
        @CatalogPrefix = @CatalogPrefix OUTPUT;

    CREATE TABLE #Columns (
        ColumnName sysname NOT NULL,
        BaseType sysname NOT NULL
    );

    SET @Sql = N'
        INSERT INTO #Columns (ColumnName, BaseType)
        SELECT c.name, bt.name
        FROM ' + @CatalogPrefix + N'sys.columns AS c
        INNER JOIN ' + @CatalogPrefix + N'sys.objects AS t
            ON t.object_id = c.object_id
        INNER JOIN ' + @CatalogPrefix + N'sys.schemas AS s
            ON s.schema_id = t.schema_id
        INNER JOIN ' + @CatalogPrefix + N'sys.types AS bt
            ON bt.system_type_id = c.system_type_id
           AND bt.user_type_id = bt.system_type_id
        WHERE s.name = @SchemaName
          AND t.name = @TableName
          AND t.type IN (N''U'', N''V'');';

    EXEC sys.sp_executesql
        @Sql,
        N'@SchemaName sysname, @TableName sysname',
        @SchemaName = @ResolvedSchema,
        @TableName = @ResolvedTable;

    DECLARE @Keys TABLE (
        Ordinal int NOT NULL,
        Item nvarchar(4000) NOT NULL,
        ResolvedName sysname NULL,
        BaseType sysname NULL
    );

    INSERT INTO @Keys (Ordinal, Item)
    SELECT Ordinal, Item
    FROM dbo.SplitCsv(@KeyColumns);

    IF EXISTS (SELECT 1 FROM @Keys WHERE Item = N'')
        THROW 50001, N'Key column list contains an empty name.', 1;

    IF EXISTS (SELECT Item FROM @Keys GROUP BY Item HAVING COUNT(*) > 1)
        THROW 50001, N'A key column was specified more than once.', 1;

    IF NOT EXISTS (SELECT 1 FROM @Keys)
        THROW 50001, N'At least one key column is required.', 1;

    UPDATE k
    SET ResolvedName = c.ColumnName,
        BaseType = c.BaseType
    FROM @Keys AS k
    INNER JOIN #Columns AS c
        ON c.ColumnName = k.Item;

    IF EXISTS (SELECT 1 FROM @Keys WHERE ResolvedName IS NULL)
    BEGIN
        SELECT @Item = MIN(Item)
        FROM @Keys
        WHERE ResolvedName IS NULL;

        SET @Message = N'Key column ''' + REPLACE(@Item, N'''', N'''''') + N''' does not exist in '
            + @Object + N'.';
        THROW 50001, @Message, 1;
    END;

    DECLARE key_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT Ordinal, ResolvedName, BaseType
        FROM @Keys
        ORDER BY Ordinal;

    OPEN key_cursor;
    FETCH NEXT FROM key_cursor INTO @Ordinal, @ResolvedName, @BaseType;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Family = dbo.Compare_TypeFamily(@BaseType);

        IF @Family IS NULL OR @BaseType IN (N'text', N'ntext', N'image', N'xml')
        BEGIN
            SET @Message = N'Key column ''' + REPLACE(@ResolvedName, N'''', N'''''')
                + N''' uses type ' + @BaseType + N', which cannot be used as a business key.';
            THROW 50001, @Message, 1;
        END;

        IF @GroupBy <> N''
        BEGIN
            SET @GroupBy += N', ';
            SET @KeyDisplay += N' + N'' | '' + ';
        END;

        SET @GroupBy += QUOTENAME(@ResolvedName);
        SET @KeyDisplay += N'ISNULL(CONVERT(nvarchar(max), ' + QUOTENAME(@ResolvedName) + N'), N''<NULL>'')';

        FETCH NEXT FROM key_cursor INTO @Ordinal, @ResolvedName, @BaseType;
    END;

    CLOSE key_cursor;
    DEALLOCATE key_cursor;

    SET @Sql = N'
        SELECT
            @TableName AS [Table],
            ' + @KeyDisplay + N' AS [Key],
            COUNT_BIG(*) AS RecordCount
        FROM ' + @Object + N'
        GROUP BY ' + @GroupBy + N'
        HAVING COUNT_BIG(*) > 1
        ORDER BY [Key];';

    EXEC sys.sp_executesql
        @Sql,
        N'@TableName sysname',
        @TableName = @ResolvedTable;
END;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.CompareTables
    @SourceDatabase sysname,
    @TargetDatabase sysname,
    @SchemaName sysname = N'dbo',
    @TableName sysname,
    @KeyColumns nvarchar(max),
    @ExcludedColumns nvarchar(max) = NULL,
    @IncludeMatches bit = 1,
    @Output varchar(20) = 'ALL',
    @Debug bit = 0,
    @SourceServer sysname = NULL,
    @TargetServer sysname = NULL,
    @IgnoreCase bit = 0,
    @Filter nvarchar(max) = NULL,
    @MaxDetailRows int = NULL,
    @IncludedColumns nvarchar(max) = NULL,
    @ExcludePatterns nvarchar(max) = NULL,
    @IgnoreBlank bit = 1,
    @MaxMatchedRows int = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @SourceDb sysname;
    DECLARE @SourceSchema sysname;
    DECLARE @SourceTable sysname;
    DECLARE @TargetDb sysname;
    DECLARE @TargetSchema sysname;
    DECLARE @TargetTable sysname;
    DECLARE @SourceObject nvarchar(1040);
    DECLARE @TargetObject nvarchar(1040);
    DECLARE @SourcePrefix nvarchar(520);
    DECLARE @TargetPrefix nvarchar(520);
    DECLARE @Message nvarchar(max);
    DECLARE @Sql nvarchar(max);
    DECLARE @LoadSql nvarchar(max);
    DECLARE @Norm nvarchar(max);
    DECLARE @ColumnName sysname;
    DECLARE @BaseType sysname;
    DECLARE @Family varchar(30);
    DECLARE @KeyOrdinal int;
    DECLARE @IsKey bit;
    DECLARE @IsCompare bit;
    DECLARE @Q nvarchar(258);
    DECLARE @Ref nvarchar(300);
    DECLARE @Inner nvarchar(max);
    DECLARE @Canon nvarchar(max);
    DECLARE @Display nvarchar(max);
    DECLARE @HashArg nvarchar(max);
    DECLARE @Fingerprint nvarchar(max);
    DECLARE @NullExpr nvarchar(max);
    DECLARE @BlankWrap nvarchar(max);
    DECLARE @KeyCmp nvarchar(max);
    DECLARE @LeftCmp nvarchar(max);
    DECLARE @RightCmp nvarchar(max);
    DECLARE @KeyNumber varchar(10);
    DECLARE @SourceKeySelect nvarchar(max) = N'';
    DECLARE @TargetKeySelect nvarchar(max) = N'';
    DECLARE @GroupBy nvarchar(max) = N'';
    DECLARE @DupSelect nvarchar(max) = N'';
    DECLARE @DupGroupBy nvarchar(max) = N'';
    DECLARE @NullSafeJoin nvarchar(max) = N'';
    DECLARE @NullSafeDelete nvarchar(max) = N'';
    DECLARE @MismatchJoin nvarchar(max) = N'';
    DECLARE @SrcDisplay nvarchar(max) = N'';
    DECLARE @TgtDisplay nvarchar(max) = N'';
    DECLARE @DupDisplay nvarchar(max) = N'';
    DECLARE @KeyFingerprints nvarchar(max) = N'';
    DECLARE @RowFingerprints nvarchar(max) = N'';
    DECLARE @DiffApply nvarchar(max) = N'';
    DECLARE @KeyHashExpr nvarchar(max);
    DECLARE @RowHashExpr nvarchar(max);
    DECLARE @Plan nvarchar(max);
    DECLARE @Offset int;
    DECLARE @Total int;
    DECLARE @FilterS nvarchar(max);
    DECLARE @FilterT nvarchar(max);
    DECLARE @FilterSrc nvarchar(max);
    DECLARE @FilterTgt nvarchar(max);
    DECLARE @EmitSchemaSql nvarchar(max);
    DECLARE @SourceRowHashSelect nvarchar(max);
    DECLARE @TargetRowHashSelect nvarchar(max);
    DECLARE @StatusExpr nvarchar(max);
    DECLARE @SampleSql nvarchar(max);
    DECLARE @SampleKeyList nvarchar(max);
    DECLARE @HashJoin nvarchar(10);

    SET @IncludeMatches = ISNULL(@IncludeMatches, 1);
    SET @IgnoreCase = ISNULL(@IgnoreCase, 0);
    SET @IgnoreBlank = ISNULL(@IgnoreBlank, 0);
    SET @Debug = ISNULL(@Debug, 0);
    SET @Output = UPPER(LTRIM(RTRIM(ISNULL(@Output, 'ALL'))));
    SET @SchemaName = LTRIM(RTRIM(ISNULL(@SchemaName, N'dbo')));
    SET @Filter = NULLIF(LTRIM(RTRIM(@Filter)), N'');
    SET @IncludedColumns = NULLIF(LTRIM(RTRIM(@IncludedColumns)), N'');
    SET @ExcludePatterns = NULLIF(LTRIM(RTRIM(@ExcludePatterns)), N'');

    IF @Output NOT IN ('ALL', 'DETAIL', 'DIFF', 'DUPLICATES', 'SUMMARY', 'PREFLIGHT')
        THROW 50001, N'@Output must be ALL, DETAIL, DIFF, DUPLICATES, SUMMARY, or PREFLIGHT.', 1;

    IF @MaxDetailRows IS NOT NULL AND @MaxDetailRows < 1
        THROW 50001, N'@MaxDetailRows must be greater than 0.', 1;

    IF @MaxMatchedRows IS NOT NULL AND @MaxMatchedRows < 1
        THROW 50001, N'@MaxMatchedRows must be greater than 0.', 1;

    IF @IncludeMatches NOT IN (0, 1)
        THROW 50001, N'@IncludeMatches must be 0 or 1.', 1;

    IF @IgnoreCase NOT IN (0, 1)
        THROW 50001, N'@IgnoreCase must be 0 or 1.', 1;

    IF @IgnoreBlank NOT IN (0, 1)
        THROW 50001, N'@IgnoreBlank must be 0 or 1.', 1;

    IF @KeyColumns IS NULL OR LTRIM(RTRIM(@KeyColumns)) = N''
        THROW 50001, N'At least one key column is required.', 1;

    EXEC dbo.Compare_ResolveTable
        @Side = N'Source',
        @DatabaseName = @SourceDatabase,
        @SchemaName = @SchemaName,
        @TableName = @TableName,
        @ServerName = @SourceServer,
        @ResolvedDatabase = @SourceDb OUTPUT,
        @ResolvedSchema = @SourceSchema OUTPUT,
        @ResolvedTable = @SourceTable OUTPUT,
        @ResolvedObject = @SourceObject OUTPUT,
        @CatalogPrefix = @SourcePrefix OUTPUT;

    EXEC dbo.Compare_ResolveTable
        @Side = N'Target',
        @DatabaseName = @TargetDatabase,
        @SchemaName = @SchemaName,
        @TableName = @TableName,
        @ServerName = @TargetServer,
        @ResolvedDatabase = @TargetDb OUTPUT,
        @ResolvedSchema = @TargetSchema OUTPUT,
        @ResolvedTable = @TargetTable OUTPUT,
        @ResolvedObject = @TargetObject OUTPUT,
        @CatalogPrefix = @TargetPrefix OUTPUT;

    CREATE TABLE #SourceCols (
        ColumnName sysname NOT NULL,
        BaseType sysname NOT NULL,
        MaxLength int NOT NULL,
        [Precision] int NOT NULL,
        Scale int NOT NULL,
        TypeDescription nvarchar(200) NOT NULL,
        Family varchar(30) NULL
    );

    CREATE TABLE #TargetCols (
        ColumnName sysname NOT NULL,
        BaseType sysname NOT NULL,
        MaxLength int NOT NULL,
        [Precision] int NOT NULL,
        Scale int NOT NULL,
        TypeDescription nvarchar(200) NOT NULL,
        Family varchar(30) NULL
    );

    SET @LoadSql = N'
        INSERT INTO #COLS# (ColumnName, BaseType, MaxLength, [Precision], Scale, TypeDescription)
        SELECT
            c.name,
            bt.name,
            c.max_length,
            c.[precision],
            c.scale,
            bt.name + CASE
                WHEN bt.name IN (N''decimal'', N''numeric'')
                    THEN N''('' + CONVERT(nvarchar(10), c.[precision]) + N'','' + CONVERT(nvarchar(10), c.scale) + N'')''
                WHEN bt.name IN (N''varchar'', N''char'', N''varbinary'', N''binary'')
                    THEN N''('' + CASE WHEN c.max_length = -1 THEN N''max'' ELSE CONVERT(nvarchar(10), c.max_length) END + N'')''
                WHEN bt.name IN (N''nvarchar'', N''nchar'')
                    THEN N''('' + CASE WHEN c.max_length = -1 THEN N''max'' ELSE CONVERT(nvarchar(10), c.max_length / 2) END + N'')''
                WHEN bt.name IN (N''datetime2'', N''datetimeoffset'', N''time'')
                    THEN N''('' + CONVERT(nvarchar(10), c.scale) + N'')''
                ELSE N''''
            END
        FROM #DB#sys.columns AS c
        INNER JOIN #DB#sys.objects AS t
            ON t.object_id = c.object_id
        INNER JOIN #DB#sys.schemas AS s
            ON s.schema_id = t.schema_id
        INNER JOIN #DB#sys.types AS bt
            ON bt.system_type_id = c.system_type_id
           AND bt.user_type_id = bt.system_type_id
        WHERE s.name = @SchemaName
          AND t.name = @TableName
          AND t.type IN (N''U'', N''V'');';

    SET @Sql = REPLACE(REPLACE(@LoadSql, N'#COLS#', N'#SourceCols'), N'#DB#', @SourcePrefix);
    EXEC sys.sp_executesql
        @Sql,
        N'@SchemaName sysname, @TableName sysname',
        @SchemaName = @SourceSchema,
        @TableName = @SourceTable;

    SET @Sql = REPLACE(REPLACE(@LoadSql, N'#COLS#', N'#TargetCols'), N'#DB#', @TargetPrefix);
    EXEC sys.sp_executesql
        @Sql,
        N'@SchemaName sysname, @TableName sysname',
        @SchemaName = @TargetSchema,
        @TableName = @TargetTable;

    IF NOT EXISTS (SELECT 1 FROM #SourceCols)
        THROW 50001, N'No columns are visible on the source table. SELECT permission is required.', 1;

    IF NOT EXISTS (SELECT 1 FROM #TargetCols)
        THROW 50001, N'No columns are visible on the target table. SELECT permission is required.', 1;

    UPDATE #SourceCols SET Family = dbo.Compare_TypeFamily(BaseType);
    UPDATE #TargetCols SET Family = dbo.Compare_TypeFamily(BaseType);

    CREATE TABLE #Keys (
        Ordinal int NOT NULL,
        Item nvarchar(4000) NOT NULL,
        ResolvedName sysname NULL
    );

    CREATE TABLE #Excluded (
        Ordinal int NOT NULL,
        Item nvarchar(4000) NOT NULL,
        ResolvedName sysname NULL
    );

    CREATE TABLE #Included (
        Ordinal int NOT NULL,
        Item nvarchar(4000) NOT NULL,
        ResolvedName sysname NULL
    );

    CREATE TABLE #ExcludePatterns (
        Ordinal int NOT NULL,
        Item nvarchar(4000) NOT NULL,
        LikePattern nvarchar(4000) NOT NULL
    );

    INSERT INTO #Keys (Ordinal, Item)
    SELECT Ordinal, Item
    FROM dbo.SplitCsv(@KeyColumns);

    INSERT INTO #Excluded (Ordinal, Item)
    SELECT Ordinal, Item
    FROM dbo.SplitCsv(@ExcludedColumns);

    INSERT INTO #Included (Ordinal, Item)
    SELECT Ordinal, Item
    FROM dbo.SplitCsv(@IncludedColumns);

    INSERT INTO #ExcludePatterns (Ordinal, Item, LikePattern)
    SELECT Ordinal, Item, dbo.Compare_GlobToLike(Item)
    FROM dbo.SplitCsv(@ExcludePatterns);

    IF EXISTS (SELECT 1 FROM #Keys WHERE Item = N'')
        THROW 50001, N'Key column list contains an empty name.', 1;

    IF EXISTS (SELECT 1 FROM #Excluded WHERE Item = N'')
        THROW 50001, N'Excluded column list contains an empty name.', 1;

    IF EXISTS (SELECT 1 FROM #Included WHERE Item = N'')
        THROW 50001, N'Included column list contains an empty name.', 1;

    IF EXISTS (SELECT 1 FROM #ExcludePatterns WHERE Item = N'')
        THROW 50001, N'Exclude pattern list contains an empty pattern.', 1;

    IF NOT EXISTS (SELECT 1 FROM #Keys)
        THROW 50001, N'At least one key column is required.', 1;

    IF (SELECT COUNT(*) FROM #Keys) > 32
        THROW 50001, N'At most 32 key columns are supported.', 1;

    IF EXISTS (SELECT Item FROM #Keys GROUP BY Item HAVING COUNT(*) > 1)
        THROW 50001, N'A key column was specified more than once.', 1;

    IF EXISTS (SELECT Item FROM #Excluded GROUP BY Item HAVING COUNT(*) > 1)
        THROW 50001, N'An excluded column was specified more than once.', 1;

    IF EXISTS (SELECT Item FROM #Included GROUP BY Item HAVING COUNT(*) > 1)
        THROW 50001, N'An included column was specified more than once.', 1;

    IF EXISTS (SELECT Item FROM #ExcludePatterns GROUP BY Item HAVING COUNT(*) > 1)
        THROW 50001, N'An exclude pattern was specified more than once.', 1;

    UPDATE k
    SET ResolvedName = c.ColumnName
    FROM #Keys AS k
    INNER JOIN #SourceCols AS c
        ON c.ColumnName = k.Item;

    UPDATE e
    SET ResolvedName = COALESCE(s.ColumnName, t.ColumnName)
    FROM #Excluded AS e
    LEFT JOIN #SourceCols AS s
        ON s.ColumnName = e.Item
    LEFT JOIN #TargetCols AS t
        ON t.ColumnName = e.Item;

    UPDATE i
    SET ResolvedName = CASE
        WHEN s.ColumnName IS NOT NULL AND t.ColumnName IS NOT NULL THEN s.ColumnName
        ELSE NULL
    END
    FROM #Included AS i
    LEFT JOIN #SourceCols AS s
        ON s.ColumnName = i.Item
    LEFT JOIN #TargetCols AS t
        ON t.ColumnName = i.Item;

    INSERT INTO #Excluded (Ordinal, Item, ResolvedName)
    SELECT
        100000 + ROW_NUMBER() OVER (ORDER BY c.ColumnName),
        c.ColumnName,
        c.ColumnName
    FROM (
        SELECT s.ColumnName
        FROM #SourceCols AS s
        UNION
        SELECT t.ColumnName
        FROM #TargetCols AS t
    ) AS c
    WHERE EXISTS (
        SELECT 1
        FROM #ExcludePatterns AS p
        WHERE c.ColumnName LIKE p.LikePattern
    )
      AND NOT EXISTS (
          SELECT 1
          FROM #Excluded AS e
          WHERE e.ResolvedName = c.ColumnName
             OR e.Item = c.ColumnName
      );

    CREATE TABLE #Issues (
        Issue nvarchar(2000) NOT NULL
    );

    INSERT INTO #Issues (Issue)
    SELECT N'Key column ''' + REPLACE(Item, N'''', N'''''') + N''' does not exist in the source table.'
    FROM #Keys
    WHERE ResolvedName IS NULL;

    INSERT INTO #Issues (Issue)
    SELECT N'Key column ''' + REPLACE(k.ResolvedName, N'''', N'''''') + N''' does not exist in the target table.'
    FROM #Keys AS k
    WHERE k.ResolvedName IS NOT NULL
      AND NOT EXISTS (
          SELECT 1
          FROM #TargetCols AS t
          WHERE t.ColumnName = k.ResolvedName
      );

    INSERT INTO #Issues (Issue)
    SELECT N'Excluded column ''' + REPLACE(Item, N'''', N'''''') + N''' does not exist in either table.'
    FROM #Excluded
    WHERE ResolvedName IS NULL;

    INSERT INTO #Issues (Issue)
    SELECT N'Included column ''' + REPLACE(Item, N'''', N'''''') + N''' does not exist in both tables.'
    FROM #Included
    WHERE ResolvedName IS NULL
      AND NOT EXISTS (SELECT 1 FROM #Keys AS k WHERE k.Item = #Included.Item);

    INSERT INTO #Issues (Issue)
    SELECT N'Key column ''' + REPLACE(k.ResolvedName, N'''', N'''''') + N''' cannot be excluded.'
    FROM #Keys AS k
    INNER JOIN #Excluded AS e
        ON e.ResolvedName = k.ResolvedName;

    INSERT INTO #Issues (Issue)
    SELECT N'Column ''' + REPLACE(i.ResolvedName, N'''', N'''''') + N''' is both included and excluded.'
    FROM #Included AS i
    INNER JOIN #Excluded AS e
        ON e.ResolvedName = i.ResolvedName
    WHERE i.ResolvedName IS NOT NULL;

    INSERT INTO #Issues (Issue)
    SELECT N'Key column ''' + REPLACE(k.ResolvedName, N'''', N'''''') + N''' uses type '
        + s.BaseType + N', which cannot be used as a business key.'
    FROM #Keys AS k
    INNER JOIN #SourceCols AS s
        ON s.ColumnName = k.ResolvedName
    WHERE s.Family IS NULL
       OR s.BaseType IN (N'text', N'ntext', N'image', N'xml');

    INSERT INTO #Issues (Issue)
    SELECT N'Key column ''' + REPLACE(k.ResolvedName, N'''', N'''''')
        + N''' is not compatible. Source type: ' + s.TypeDescription
        + N'. Target type: ' + t.TypeDescription + N'.'
    FROM #Keys AS k
    INNER JOIN #SourceCols AS s
        ON s.ColumnName = k.ResolvedName
    INNER JOIN #TargetCols AS t
        ON t.ColumnName = k.ResolvedName
    WHERE s.Family IS NOT NULL
      AND s.BaseType NOT IN (N'text', N'ntext', N'image', N'xml')
      AND dbo.Compare_TypesAreCompatible(
            s.Family, s.BaseType, s.MaxLength, s.Scale,
            t.Family, t.BaseType, t.MaxLength, t.Scale
          ) = 0;

    /* Common non-key columns that will be compared must be comparable. */
    INSERT INTO #Issues (Issue)
    SELECT N'Column ''' + REPLACE(s.ColumnName, N'''', N'''''') + N''' uses unsupported type '
        + s.TypeDescription + N'. Exclude it with @ExcludedColumns or omit it from @IncludedColumns.'
    FROM #SourceCols AS s
    INNER JOIN #TargetCols AS t
        ON t.ColumnName = s.ColumnName
    WHERE s.Family IS NULL
      AND NOT EXISTS (SELECT 1 FROM #Keys AS k WHERE k.ResolvedName = s.ColumnName)
      AND NOT EXISTS (SELECT 1 FROM #Excluded AS e WHERE e.ResolvedName = s.ColumnName)
      AND (
          NOT EXISTS (SELECT 1 FROM #Included)
          OR EXISTS (SELECT 1 FROM #Included AS i WHERE i.ResolvedName = s.ColumnName)
      );

    INSERT INTO #Issues (Issue)
    SELECT N'Column ''' + REPLACE(s.ColumnName, N'''', N'''''')
        + N''' is not compatible. Source type: ' + s.TypeDescription
        + N'. Target type: ' + t.TypeDescription
        + N'. Align the types or exclude the column.'
    FROM #SourceCols AS s
    INNER JOIN #TargetCols AS t
        ON t.ColumnName = s.ColumnName
    WHERE s.Family IS NOT NULL
      AND t.Family IS NOT NULL
      AND dbo.Compare_TypesAreCompatible(
            s.Family, s.BaseType, s.MaxLength, s.Scale,
            t.Family, t.BaseType, t.MaxLength, t.Scale
          ) = 0
      AND NOT EXISTS (SELECT 1 FROM #Keys AS k WHERE k.ResolvedName = s.ColumnName)
      AND NOT EXISTS (SELECT 1 FROM #Excluded AS e WHERE e.ResolvedName = s.ColumnName)
      AND (
          NOT EXISTS (SELECT 1 FROM #Included)
          OR EXISTS (SELECT 1 FROM #Included AS i WHERE i.ResolvedName = s.ColumnName)
      );

    IF EXISTS (SELECT 1 FROM #Issues)
    BEGIN
        SELECT @Message = STUFF((
            SELECT N' ' + Issue
            FROM #Issues
            ORDER BY Issue
            FOR XML PATH(''), TYPE
        ).value(N'.', N'nvarchar(max)'), 1, 1, N'');

        IF LEN(@Message) > 2048
            SET @Message = LEFT(@Message, 2045) + N'...';

        THROW 50001, @Message, 1;
    END;

    CREATE TABLE #Common (
        ColumnName sysname NOT NULL,
        BaseType sysname NOT NULL,
        Family varchar(30) NOT NULL,
        IsKey bit NOT NULL,
        KeyOrdinal int NULL,
        IsCompare bit NOT NULL
    );

    INSERT INTO #Common (ColumnName, BaseType, Family, IsKey, KeyOrdinal, IsCompare)
    SELECT
        s.ColumnName,
        s.BaseType,
        s.Family,
        CASE WHEN k.ResolvedName IS NOT NULL THEN 1 ELSE 0 END,
        k.Ordinal,
        CASE
            WHEN k.ResolvedName IS NOT NULL THEN 0
            WHEN e.ResolvedName IS NOT NULL THEN 0
            WHEN EXISTS (SELECT 1 FROM #Included)
                 AND NOT EXISTS (SELECT 1 FROM #Included AS i WHERE i.ResolvedName = s.ColumnName)
                THEN 0
            ELSE 1
        END
    FROM #SourceCols AS s
    INNER JOIN #TargetCols AS t
        ON t.ColumnName = s.ColumnName
    LEFT JOIN #Keys AS k
        ON k.ResolvedName = s.ColumnName
    LEFT JOIN #Excluded AS e
        ON e.ResolvedName = s.ColumnName
    WHERE s.Family IS NOT NULL;

    CREATE TABLE #AllowedFilterCols (
        ColumnName sysname NOT NULL PRIMARY KEY
    );

    INSERT INTO #AllowedFilterCols (ColumnName)
    SELECT s.ColumnName
    FROM #SourceCols AS s
    INNER JOIN #TargetCols AS t
        ON t.ColumnName = s.ColumnName;

    IF @Filter IS NOT NULL
    BEGIN
        EXEC dbo.Compare_BuildFilter
            @Filter = @Filter,
            @Alias = NULL,
            @WhereSql = @FilterS OUTPUT;

        EXEC dbo.Compare_BuildFilter
            @Filter = @Filter,
            @Alias = N's',
            @WhereSql = @FilterS OUTPUT;

        EXEC dbo.Compare_BuildFilter
            @Filter = @Filter,
            @Alias = N't',
            @WhereSql = @FilterT OUTPUT;

        EXEC dbo.Compare_BuildFilter
            @Filter = @Filter,
            @Alias = N'src',
            @WhereSql = @FilterSrc OUTPUT;

        EXEC dbo.Compare_BuildFilter
            @Filter = @Filter,
            @Alias = N'tgt',
            @WhereSql = @FilterTgt OUTPUT;
    END;

    CREATE TABLE #SchemaPlan (
        [Table] sysname NOT NULL,
        [Column] sysname NOT NULL,
        Side varchar(20) NOT NULL,
        Role varchar(20) NOT NULL,
        SourceType nvarchar(128) NULL,
        TargetType nvarchar(128) NULL,
        SortOrder int NOT NULL
    );

    INSERT INTO #SchemaPlan ([Table], [Column], Side, Role, SourceType, TargetType, SortOrder)
    SELECT
        @SourceTable,
        s.ColumnName,
        CONVERT(varchar(20), 'BOTH'),
        CONVERT(varchar(20), CASE
            WHEN k.ResolvedName IS NOT NULL THEN 'KEY'
            WHEN e.ResolvedName IS NOT NULL THEN 'EXCLUDED'
            WHEN c.IsCompare = 1 THEN 'COMPARE'
            ELSE 'SKIPPED'
        END),
        s.TypeDescription,
        t.TypeDescription,
        1
    FROM #SourceCols AS s
    INNER JOIN #TargetCols AS t
        ON t.ColumnName = s.ColumnName
    LEFT JOIN #Keys AS k
        ON k.ResolvedName = s.ColumnName
    LEFT JOIN #Excluded AS e
        ON e.ResolvedName = s.ColumnName
    LEFT JOIN #Common AS c
        ON c.ColumnName = s.ColumnName
    UNION ALL
    SELECT
        @SourceTable,
        s.ColumnName,
        'SOURCE_ONLY',
        'SOURCE_ONLY',
        s.TypeDescription,
        NULL,
        2
    FROM #SourceCols AS s
    WHERE NOT EXISTS (SELECT 1 FROM #TargetCols AS t WHERE t.ColumnName = s.ColumnName)
    UNION ALL
    SELECT
        @SourceTable,
        t.ColumnName,
        'TARGET_ONLY',
        'TARGET_ONLY',
        NULL,
        t.TypeDescription,
        3
    FROM #TargetCols AS t
    WHERE NOT EXISTS (SELECT 1 FROM #SourceCols AS s WHERE s.ColumnName = t.ColumnName);

    SET @EmitSchemaSql = N'
    SELECT
        [Table],
        [Column],
        Side,
        Role,
        SourceType,
        TargetType
    FROM #SchemaPlan
    ORDER BY SortOrder, [Column];';

    SELECT @Plan = N'CompareTables: ' + @SourceObject + N' -> ' + @TargetObject
        + N'. Keys: ' + ISNULL(STUFF((
            SELECT N', ' + ColumnName
            FROM #Common
            WHERE IsKey = 1
            ORDER BY KeyOrdinal
            FOR XML PATH(''), TYPE
        ).value(N'.', N'nvarchar(max)'), 1, 2, N''), N'(none)')
        + N'. Comparing: ' + ISNULL(NULLIF(STUFF((
            SELECT N', ' + ColumnName
            FROM #Common
            WHERE IsCompare = 1
            ORDER BY ColumnName
            FOR XML PATH(''), TYPE
        ).value(N'.', N'nvarchar(max)'), 1, 2, N''), N''), N'(key only)')
        + CASE
            WHEN EXISTS (SELECT 1 FROM #Included WHERE ResolvedName IS NOT NULL)
                THEN N'. Included: ' + STUFF((
                    SELECT N', ' + ResolvedName
                    FROM #Included
                    WHERE ResolvedName IS NOT NULL
                    ORDER BY ResolvedName
                    FOR XML PATH(''), TYPE
                ).value(N'.', N'nvarchar(max)'), 1, 2, N'')
            ELSE N''
          END
        + CASE
            WHEN EXISTS (SELECT 1 FROM #Excluded WHERE ResolvedName IS NOT NULL)
                THEN N'. Excluded: ' + STUFF((
                    SELECT N', ' + ResolvedName
                    FROM #Excluded
                    WHERE ResolvedName IS NOT NULL
                    ORDER BY ResolvedName
                    FOR XML PATH(''), TYPE
                ).value(N'.', N'nvarchar(max)'), 1, 2, N'')
            ELSE N''
          END
        + CASE
            WHEN EXISTS (SELECT 1 FROM #ExcludePatterns)
                THEN N'. Exclude patterns: ' + STUFF((
                    SELECT N', ' + Item
                    FROM #ExcludePatterns
                    ORDER BY Ordinal
                    FOR XML PATH(''), TYPE
                ).value(N'.', N'nvarchar(max)'), 1, 2, N'')
            ELSE N''
          END
        + CASE WHEN @Filter IS NOT NULL THEN N'. Filter: ' + @Filter ELSE N'' END
        + CASE
            WHEN @MaxMatchedRows IS NOT NULL
                THEN N'. Value comparison limited to the first '
                    + CONVERT(nvarchar(20), @MaxMatchedRows)
                    + N' matched keys.'
            ELSE N''
          END
        + CASE WHEN @IgnoreCase = 1 THEN N'. Strings are compared case-insensitively.' ELSE N'' END
        + CASE WHEN @IgnoreBlank = 1 THEN N'. Strings are trimmed, and blank text matches NULL.' ELSE N'' END
        + CASE WHEN @Output = 'PREFLIGHT' THEN N'. Preflight only; rows were not scanned.' ELSE N'' END;

    PRINT @Plan;

    IF EXISTS (SELECT 1 FROM #SchemaPlan WHERE Side = 'SOURCE_ONLY')
    BEGIN
        SET @Message = N'Source-only columns were not compared: ' + STUFF((
            SELECT N', ' + [Column]
            FROM #SchemaPlan
            WHERE Side = 'SOURCE_ONLY'
            ORDER BY [Column]
            FOR XML PATH(''), TYPE
        ).value(N'.', N'nvarchar(max)'), 1, 2, N'');
        PRINT @Message;
    END;

    IF EXISTS (SELECT 1 FROM #SchemaPlan WHERE Side = 'TARGET_ONLY')
    BEGIN
        SET @Message = N'Target-only columns were not compared: ' + STUFF((
            SELECT N', ' + [Column]
            FROM #SchemaPlan
            WHERE Side = 'TARGET_ONLY'
            ORDER BY [Column]
            FOR XML PATH(''), TYPE
        ).value(N'.', N'nvarchar(max)'), 1, 2, N'');
        PRINT @Message;
    END;

    IF @Output = 'PREFLIGHT'
    BEGIN
        EXEC sys.sp_executesql @EmitSchemaSql;
        RETURN;
    END;

    /*
        Strip trailing fractional zeros without touching zeros that are part of the
        number. 10.50 and 10.5000 both become 10.5; 101.00 stays distinct from 110.00.
    */
    SET @Norm = N'CASE WHEN CHARINDEX(N''.'', {raw}) = 0 THEN {raw} ELSE CASE WHEN RIGHT(LEFT({raw}, LEN({raw}) - PATINDEX(N''%[^0]%'', REVERSE({raw})) + 1), 1) = N''.'' THEN LEFT(LEFT({raw}, LEN({raw}) - PATINDEX(N''%[^0]%'', REVERSE({raw})) + 1), LEN(LEFT({raw}, LEN({raw}) - PATINDEX(N''%[^0]%'', REVERSE({raw})) + 1)) - 1) ELSE LEFT({raw}, LEN({raw}) - PATINDEX(N''%[^0]%'', REVERSE({raw})) + 1) END END';

    /*
        Turn tab, newline, and non-breaking space into a normal space, trim, then
        treat a blank result as NULL. LTRIM/RTRIM alone leave NCHAR(160) in place,
        so a value that looks empty still differs from NULL.
    */
    SET @BlankWrap = N'NULLIF(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE({expr}, NCHAR(9), N'' ''), NCHAR(10), N'' ''), NCHAR(11), N'' ''), NCHAR(12), N'' ''), NCHAR(13), N'' ''), NCHAR(160), N'' ''), NCHAR(8239), N'' ''), NCHAR(12288), N'' ''))), N'''')';

    DECLARE column_cursor CURSOR LOCAL FAST_FORWARD FOR
        SELECT ColumnName, BaseType, Family, KeyOrdinal, IsKey, IsCompare
        FROM #Common
        WHERE IsKey = 1 OR IsCompare = 1
        ORDER BY IsKey DESC, ISNULL(KeyOrdinal, 0), ColumnName;

    OPEN column_cursor;
    FETCH NEXT FROM column_cursor INTO @ColumnName, @BaseType, @Family, @KeyOrdinal, @IsKey, @IsCompare;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Q = QUOTENAME(@ColumnName);
        SET @Ref = N'#A#.' + @Q;
        SET @Canon = NULL;
        SET @Inner = NULL;

        IF @BaseType IN (N'binary', N'varbinary', N'image', N'timestamp')
        BEGIN
            SET @HashArg = N'CONVERT(varbinary(max), ' + @Ref + N')';
            SET @Display = N'CASE WHEN ' + @Ref + N' IS NULL THEN CAST(NULL AS nvarchar(max)) WHEN DATALENGTH('
                + @Ref + N') <= 64 THEN CONVERT(nvarchar(max), ' + @Ref
                + N', 1) ELSE CONVERT(nvarchar(200), SUBSTRING(' + @Ref
                + N', 1, 64), 1) + N''... ('' + CONVERT(nvarchar(20), DATALENGTH(' + @Ref
                + N')) + N'' bytes)'' END';
        END
        ELSE
        BEGIN
            SET @Inner = CASE
                WHEN @Family = 'integer' OR @BaseType = N'bit'
                    THEN N'CONVERT(nvarchar(30), ' + @Ref + N')'
                WHEN @Family = 'decimal'
                    THEN N'CONVERT(nvarchar(100), ' + @Ref + N')'
                WHEN @BaseType = N'money'
                    THEN N'CONVERT(nvarchar(100), CONVERT(decimal(19,4), ' + @Ref + N'))'
                WHEN @BaseType = N'smallmoney'
                    THEN N'CONVERT(nvarchar(100), CONVERT(decimal(10,4), ' + @Ref + N'))'
                WHEN @BaseType IN (N'float', N'real')
                    THEN N'CONVERT(nvarchar(50), ' + @Ref + N', 3)'
                WHEN @BaseType = N'date'
                    THEN N'CONVERT(nvarchar(10), ' + @Ref + N', 23)'
                WHEN @BaseType = N'time'
                    THEN N'CONVERT(nvarchar(20), ' + @Ref + N', 121)'
                WHEN @BaseType IN (N'datetime', N'smalldatetime', N'datetime2')
                    THEN N'CONVERT(nvarchar(40), ' + @Ref + N', 121)'
                WHEN @BaseType = N'datetimeoffset'
                    THEN N'CONVERT(nvarchar(40), ' + @Ref + N', 127)'
                WHEN @BaseType = N'uniqueidentifier'
                    THEN N'CONVERT(nvarchar(36), ' + @Ref + N')'
                ELSE N'CONVERT(nvarchar(max), ' + @Ref + N')'
            END;

            IF @Family IN ('decimal', 'money')
                SET @Canon = REPLACE(@Norm, N'{raw}', @Inner);
            ELSE
                SET @Canon = @Inner;

            /* Fold case only for the equality hash. Display stays the original text. */
            IF @IgnoreCase = 1 AND @Family = 'string'
                SET @Canon = N'UPPER(' + @Canon + N')';

            /*
                Display still uses @Inner, so a real mismatch shows the original text.
                Blank keys use the same form so '    ' and NULL are one key.
            */
            IF @IgnoreBlank = 1 AND @Family = 'string'
                SET @Canon = REPLACE(@BlankWrap, N'{expr}', @Canon);

            SET @HashArg = N'CONVERT(varbinary(max), ' + @Canon + N')';
            SET @Display = N'CONVERT(nvarchar(max), ' + @Inner + N')';
        END;

        SET @NullExpr = @Ref;
        IF @IgnoreBlank = 1 AND @Family = 'string'
            SET @NullExpr = @Canon;

        SET @Fingerprint = N'CONVERT(varbinary(max), CASE WHEN ' + @NullExpr
            + N' IS NULL THEN CONVERT(binary(33), 0x00) ELSE CONVERT(binary(33), 0x01 + HASHBYTES(''SHA2_256'', '
            + @HashArg + N')) END)';

        IF @IsKey = 1
        BEGIN
            SET @KeyNumber = CONVERT(varchar(10), @KeyOrdinal);

            IF @SourceKeySelect <> N''
            BEGIN
                SET @SourceKeySelect += N',' + NCHAR(10) + N'        ';
                SET @TargetKeySelect += N',' + NCHAR(10) + N'        ';
                SET @GroupBy += N', ';
                SET @DupSelect += N', ';
                SET @DupGroupBy += N', ';
                SET @NullSafeJoin += N' AND ';
                SET @NullSafeDelete += N' AND ';
                SET @MismatchJoin += N' AND ';
                SET @SrcDisplay += N' + N'' | '' + ';
                SET @TgtDisplay += N' + N'' | '' + ';
                SET @DupDisplay += N' + N'' | '' + ';
                SET @KeyFingerprints += N' + ';
            END;

            SET @SourceKeySelect += N's.' + @Q + N' AS K' + @KeyNumber;
            SET @TargetKeySelect += N't.' + @Q + N' AS K' + @KeyNumber;
            SET @GroupBy += N'K' + @KeyNumber;
            IF @Family = 'string' AND (@IgnoreCase = 1 OR @IgnoreBlank = 1)
            BEGIN
                SET @KeyCmp = N'CONVERT(nvarchar(max), #K#)';
                IF @IgnoreCase = 1
                    SET @KeyCmp = N'UPPER(' + @KeyCmp + N')';
                IF @IgnoreBlank = 1
                    SET @KeyCmp = REPLACE(@BlankWrap, N'{expr}', @KeyCmp);
                SET @DupSelect += N'MIN(K' + @KeyNumber + N') AS K' + @KeyNumber;
                SET @DupGroupBy += REPLACE(@KeyCmp, N'#K#', N'K' + @KeyNumber);
                SET @LeftCmp = REPLACE(@KeyCmp, N'#K#', N's.K' + @KeyNumber);
                SET @RightCmp = REPLACE(@KeyCmp, N'#K#', N't.K' + @KeyNumber);
                SET @NullSafeJoin += N'(' + @LeftCmp + N' = ' + @RightCmp
                    + N' OR (' + @LeftCmp + N' IS NULL AND ' + @RightCmp + N' IS NULL))';
                SET @LeftCmp = REPLACE(@KeyCmp, N'#K#', N's.K' + @KeyNumber);
                SET @RightCmp = REPLACE(@KeyCmp, N'#K#', N'd.K' + @KeyNumber);
                SET @NullSafeDelete += N'(' + @LeftCmp + N' = ' + @RightCmp
                    + N' OR (' + @LeftCmp + N' IS NULL AND ' + @RightCmp + N' IS NULL))';
                SET @LeftCmp = REPLACE(@KeyCmp, N'#K#', N'c.K' + @KeyNumber);
                SET @RightCmp = REPLACE(@KeyCmp, N'#K#', N'#ROW#.' + @Q);
                SET @MismatchJoin += N'(' + @LeftCmp + N' = ' + @RightCmp
                    + N' OR (' + @LeftCmp + N' IS NULL AND ' + @RightCmp + N' IS NULL))';
            END
            ELSE
            BEGIN
                SET @DupSelect += N'K' + @KeyNumber;
                SET @DupGroupBy += N'K' + @KeyNumber;
                SET @NullSafeJoin += N'(s.K' + @KeyNumber + N' = t.K' + @KeyNumber
                    + N' OR (s.K' + @KeyNumber + N' IS NULL AND t.K' + @KeyNumber + N' IS NULL))';
                SET @NullSafeDelete += N'(s.K' + @KeyNumber + N' = d.K' + @KeyNumber
                    + N' OR (s.K' + @KeyNumber + N' IS NULL AND d.K' + @KeyNumber + N' IS NULL))';
                SET @MismatchJoin += N'(c.K' + @KeyNumber + N' = #ROW#.' + @Q
                    + N' OR (c.K' + @KeyNumber + N' IS NULL AND #ROW#.' + @Q + N' IS NULL))';
            END;
            SET @SrcDisplay += N'ISNULL(CONVERT(nvarchar(max), s.K' + @KeyNumber + N'), N''<NULL>'')';
            SET @TgtDisplay += N'ISNULL(CONVERT(nvarchar(max), t.K' + @KeyNumber + N'), N''<NULL>'')';
            SET @DupDisplay += N'ISNULL(CONVERT(nvarchar(max), d.K' + @KeyNumber + N'), N''<NULL>'')';
            SET @KeyFingerprints += @Fingerprint;
        END
        ELSE
        BEGIN
            IF @RowFingerprints <> N''
                SET @RowFingerprints += N' + ';

            SET @RowFingerprints += @Fingerprint;

            IF @DiffApply <> N''
                SET @DiffApply += NCHAR(10) + N'            UNION ALL' + NCHAR(10);

            SET @DiffApply += N'            SELECT CONVERT(nvarchar(128), N'''
                + REPLACE(@ColumnName, N'''', N'''''') + N''') AS ColumnName, '
                + REPLACE(@Display, N'#A#', N'src') + N' AS SourceValue, '
                + REPLACE(@Display, N'#A#', N'tgt') + N' AS TargetValue, ';

            IF @BaseType IN (N'binary', N'varbinary', N'image', N'timestamp')
            BEGIN
                SET @DiffApply += N'CASE WHEN src.' + @Q + N' IS NULL AND tgt.' + @Q
                    + N' IS NULL THEN 0 WHEN src.' + @Q + N' IS NULL OR tgt.' + @Q
                    + N' IS NULL THEN 1 WHEN src.' + @Q + N' = tgt.' + @Q
                    + N' THEN 0 ELSE 1 END AS IsDiff';
            END
            ELSE IF @IgnoreBlank = 1 AND @Family = 'string'
            BEGIN
                SET @DiffApply += N'CASE WHEN ' + REPLACE(@Canon, N'#A#', N'src')
                    + N' IS NULL AND ' + REPLACE(@Canon, N'#A#', N'tgt')
                    + N' IS NULL THEN 0 WHEN ' + REPLACE(@Canon, N'#A#', N'src')
                    + N' IS NULL OR ' + REPLACE(@Canon, N'#A#', N'tgt')
                    + N' IS NULL THEN 1 WHEN '
                    + REPLACE(@Canon, N'#A#', N'src') + N' = ' + REPLACE(@Canon, N'#A#', N'tgt')
                    + N' AND DATALENGTH(' + REPLACE(@Canon, N'#A#', N'src') + N') = DATALENGTH('
                    + REPLACE(@Canon, N'#A#', N'tgt') + N') THEN 0 ELSE 1 END AS IsDiff';
            END
            ELSE
            BEGIN
                SET @DiffApply += N'CASE WHEN src.' + @Q + N' IS NULL AND tgt.' + @Q
                    + N' IS NULL THEN 0 WHEN src.' + @Q + N' IS NULL OR tgt.' + @Q
                    + N' IS NULL THEN 1 WHEN '
                    + REPLACE(@Canon, N'#A#', N'src') + N' = ' + REPLACE(@Canon, N'#A#', N'tgt')
                    + N' AND DATALENGTH(' + REPLACE(@Canon, N'#A#', N'src') + N') = DATALENGTH('
                    + REPLACE(@Canon, N'#A#', N'tgt') + N') THEN 0 ELSE 1 END AS IsDiff';
            END;
        END;

        FETCH NEXT FROM column_cursor INTO @ColumnName, @BaseType, @Family, @KeyOrdinal, @IsKey, @IsCompare;
    END;

    CLOSE column_cursor;
    DEALLOCATE column_cursor;

    /* binary(32) keeps the join key indexable. HASHBYTES over varbinary(max) is otherwise typed as varbinary(8000). */
    SET @KeyHashExpr = N'CONVERT(binary(32), HASHBYTES(''SHA2_256'', ' + @KeyFingerprints + N'))';

    IF @RowFingerprints = N''
        SET @RowHashExpr = N'CONVERT(binary(32), HASHBYTES(''SHA2_256'', 0x))';
    ELSE
        SET @RowHashExpr = N'CONVERT(binary(32), HASHBYTES(''SHA2_256'', ' + @RowFingerprints + N'))';

    /*
        @MaxMatchedRows limits the column-value comparison to the first N keys
        present on both sides. Key presence, duplicates, and row counts still
        cover the whole table. Row hashes are computed only for that sample.
    */
    SET @SampleKeyList = REPLACE(@GroupBy, N'K', N'c.K');
    SET @HashJoin = CASE
        WHEN NULLIF(LTRIM(RTRIM(@SourceServer)), N'') IS NULL
         AND NULLIF(LTRIM(RTRIM(@TargetServer)), N'') IS NULL THEN N'HASH '
        ELSE N''
    END;

    IF @MaxMatchedRows IS NULL
    BEGIN
        SET @SourceRowHashSelect = N',
        ' + REPLACE(@RowHashExpr, N'#A#', N's') + N' AS RowHash';
        SET @TargetRowHashSelect = N',
        ' + REPLACE(@RowHashExpr, N'#A#', N't') + N' AS RowHash';
        SET @StatusExpr = N'CASE
        WHEN s.HasRow IS NULL THEN ''ONLY_IN_TARGET''
        WHEN t.HasRow IS NULL THEN ''ONLY_IN_SOURCE''
        WHEN s.RowHash = t.RowHash THEN ''MATCH''
        ELSE ''VALUE_MISMATCH''
    END';
        SET @SampleSql = N'
SELECT
    @MatchedKeys = ISNULL(SUM(CASE WHEN [Status] IN (''MATCH'', ''VALUE_MISMATCH'') THEN CONVERT(bigint, 1) ELSE 0 END), 0),
    @ComparedMatchedRows = ISNULL(SUM(CASE WHEN [Status] IN (''MATCH'', ''VALUE_MISMATCH'') THEN CONVERT(bigint, 1) ELSE 0 END), 0)
FROM #Classified;';
    END
    ELSE
    BEGIN
        SET @SourceRowHashSelect = N'';
        SET @TargetRowHashSelect = N'';
        SET @StatusExpr = N'CASE
        WHEN s.HasRow IS NULL THEN ''ONLY_IN_TARGET''
        WHEN t.HasRow IS NULL THEN ''ONLY_IN_SOURCE''
        ELSE ''BOTH''
    END';
        SET @SampleSql = N'
SELECT @MatchedKeys = COUNT_BIG(*)
FROM #Classified
WHERE [Status] = ''BOTH'';

SELECT TOP (@MaxMatchedRows)
    c.KeyDisplay,
    c.KeyHash,
    ' + @SampleKeyList + N'
INTO #MatchedSample
FROM #Classified AS c
WHERE c.[Status] = ''BOTH''
ORDER BY c.KeyDisplay, ' + @SampleKeyList + N';

SELECT
    c.KeyDisplay,
    CASE WHEN srcH.RowHash = tgtH.RowHash THEN ''MATCH'' ELSE ''VALUE_MISMATCH'' END AS [Status],
    c.KeyHash,
    ' + @SampleKeyList + N'
INTO #SampledClass
FROM #MatchedSample AS c
INNER ' + @HashJoin + N'JOIN ' + @SourceObject + N' AS src
    ON ' + REPLACE(@KeyHashExpr, N'#A#', N'src') + N' = c.KeyHash
INNER ' + @HashJoin + N'JOIN ' + @TargetObject + N' AS tgt
    ON ' + REPLACE(@KeyHashExpr, N'#A#', N'tgt') + N' = c.KeyHash
CROSS APPLY (
    SELECT CASE WHEN c.KeyHash IS NOT NULL THEN ' + REPLACE(@RowHashExpr, N'#A#', N'src') + N' END AS RowHash
) AS srcH
CROSS APPLY (
    SELECT CASE WHEN c.KeyHash IS NOT NULL THEN ' + REPLACE(@RowHashExpr, N'#A#', N'tgt') + N' END AS RowHash
) AS tgtH
WHERE ' + REPLACE(@MismatchJoin, N'#ROW#', N'src') + N'
  AND ' + REPLACE(@MismatchJoin, N'#ROW#', N'tgt')
            + CASE WHEN @FilterSrc IS NULL THEN N'' ELSE N'
  AND ' + @FilterSrc END
            + CASE WHEN @FilterTgt IS NULL THEN N'' ELSE N'
  AND ' + @FilterTgt END + N';

DELETE FROM #Classified WHERE [Status] = ''BOTH'';

INSERT INTO #Classified (KeyDisplay, [Status], KeyHash, ' + @GroupBy + N')
SELECT KeyDisplay, [Status], KeyHash, ' + @GroupBy + N'
FROM #SampledClass;

SELECT @ComparedMatchedRows = COUNT_BIG(*)
FROM #SampledClass;';
    END;

    SET @Sql = N'
SET NOCOUNT ON;

SELECT
        ' + @SourceKeySelect + N',
        ' + REPLACE(@KeyHashExpr, N'#A#', N's') + N' AS KeyHash' + @SourceRowHashSelect + N',
        CAST(1 AS bit) AS HasRow
INTO #SourceHash
FROM ' + @SourceObject + N' AS s'
        + CASE WHEN @FilterS IS NULL THEN N'' ELSE N'
WHERE ' + @FilterS END + N';

SELECT
        ' + @TargetKeySelect + N',
        ' + REPLACE(@KeyHashExpr, N'#A#', N't') + N' AS KeyHash' + @TargetRowHashSelect + N',
        CAST(1 AS bit) AS HasRow
INTO #TargetHash
FROM ' + @TargetObject + N' AS t'
        + CASE WHEN @FilterT IS NULL THEN N'' ELSE N'
WHERE ' + @FilterT END + N';

DECLARE @SourceRowCount bigint;
DECLARE @TargetRowCount bigint;
DECLARE @MatchedKeys bigint = 0;
DECLARE @ComparedMatchedRows bigint = 0;
SELECT @SourceRowCount = COUNT_BIG(*) FROM #SourceHash;
SELECT @TargetRowCount = COUNT_BIG(*) FROM #TargetHash;

SELECT ' + @DupSelect + N', COUNT_BIG(*) AS RecordCount
INTO #DupSource
FROM #SourceHash
GROUP BY ' + @DupGroupBy + N'
HAVING COUNT_BIG(*) > 1;

SELECT ' + @DupSelect + N', COUNT_BIG(*) AS RecordCount
INTO #DupTarget
FROM #TargetHash
GROUP BY ' + @DupGroupBy + N'
HAVING COUNT_BIG(*) > 1;

DELETE s
FROM #SourceHash AS s
INNER JOIN #DupSource AS d
    ON ' + @NullSafeDelete + N';

DELETE t
FROM #TargetHash AS t
INNER JOIN #DupTarget AS d
    ON ' + REPLACE(@NullSafeDelete, N's.', N't.') + N';

CREATE CLUSTERED INDEX IX_SourceHash_KeyHash ON #SourceHash (KeyHash);
CREATE CLUSTERED INDEX IX_TargetHash_KeyHash ON #TargetHash (KeyHash);

SELECT
    CASE WHEN s.HasRow = 1 THEN ' + @SrcDisplay + N' ELSE ' + @TgtDisplay + N' END AS KeyDisplay,
    ' + @StatusExpr + N' AS [Status],
    COALESCE(s.KeyHash, t.KeyHash) AS KeyHash,
    ' + REPLACE(@GroupBy, N'K', N's.K') + N'
INTO #Classified
FROM #SourceHash AS s
FULL OUTER JOIN #TargetHash AS t
    ON s.KeyHash = t.KeyHash
   AND ' + @NullSafeJoin + N';
' + @SampleSql + N'

IF @Output IN (''ALL'', ''DETAIL'', ''DIFF'')
BEGIN
    SELECT' + CASE WHEN @MaxDetailRows IS NULL THEN N'' ELSE N' TOP (@MaxDetailRows)' END + N'
        [Table],
        [Key],
        [Status],
        [Column],
        SourceValue,
        TargetValue
    FROM (
        SELECT
            @TableName AS [Table],
            c.KeyDisplay AS [Key],
            c.[Status],
            CAST(NULL AS nvarchar(128)) AS [Column],
            CAST(NULL AS nvarchar(max)) AS SourceValue,
            CAST(NULL AS nvarchar(max)) AS TargetValue,
            CASE c.[Status]
                WHEN ''MATCH'' THEN 1
                WHEN ''ONLY_IN_SOURCE'' THEN 2
                WHEN ''ONLY_IN_TARGET'' THEN 3
                ELSE 4
            END AS SortStatus
        FROM #Classified AS c
        WHERE c.[Status] <> ''VALUE_MISMATCH''
          AND ((@Output <> ''DIFF'' AND @IncludeMatches = 1) OR c.[Status] <> ''MATCH'')
        ' + CASE
            WHEN @DiffApply = N'' THEN N''
            ELSE N'
        UNION ALL
        SELECT
            @TableName,
            c.KeyDisplay,
            ''VALUE_MISMATCH'',
            v.ColumnName,
            v.SourceValue,
            v.TargetValue,
            4
        FROM #Classified AS c
        INNER JOIN ' + @SourceObject + N' AS src
            ON ' + REPLACE(@MismatchJoin, N'#ROW#', N'src')
            + CASE WHEN @FilterSrc IS NULL THEN N'' ELSE N'
           AND ' + @FilterSrc END + N'
        INNER JOIN ' + @TargetObject + N' AS tgt
            ON ' + REPLACE(@MismatchJoin, N'#ROW#', N'tgt')
            + CASE WHEN @FilterTgt IS NULL THEN N'' ELSE N'
           AND ' + @FilterTgt END + N'
        CROSS APPLY (
' + @DiffApply + N'
        ) AS v
        WHERE c.[Status] = ''VALUE_MISMATCH''
          AND v.IsDiff = 1'
        END + N'
    ) AS compared
    ORDER BY
        CASE [Status]
            WHEN ''MATCH'' THEN 1
            WHEN ''ONLY_IN_SOURCE'' THEN 2
            WHEN ''ONLY_IN_TARGET'' THEN 3
            ELSE 4
        END,
        [Key],
        [Column];
END;

IF @Output IN (''ALL'', ''DUPLICATES'')
BEGIN
    SELECT
        @TableName AS [Table],
        ' + @DupDisplay + N' AS [Key],
        CONVERT(varchar(32), ''DUPLICATE_SOURCE'') AS [Status],
        d.RecordCount
    FROM #DupSource AS d
    UNION ALL
    SELECT
        @TableName,
        ' + @DupDisplay + N',
        CONVERT(varchar(32), ''DUPLICATE_TARGET''),
        d.RecordCount
    FROM #DupTarget AS d
    ORDER BY [Status], [Key];
END;

IF @Output IN (''ALL'', ''SUMMARY'')
BEGIN
    SELECT
        @TableName AS [Table],
        @SourceRowCount AS SourceRowCount,
        @TargetRowCount AS TargetRowCount,
        @SourceRowCount - @TargetRowCount AS CountDifference,
        ISNULL(SUM(CASE WHEN [Status] = ''MATCH'' THEN CONVERT(bigint, 1) ELSE 0 END), 0) AS MatchingRows,
        ISNULL(SUM(CASE WHEN [Status] = ''ONLY_IN_SOURCE'' THEN CONVERT(bigint, 1) ELSE 0 END), 0) AS OnlyInSource,
        ISNULL(SUM(CASE WHEN [Status] = ''ONLY_IN_TARGET'' THEN CONVERT(bigint, 1) ELSE 0 END), 0) AS OnlyInTarget,
        ISNULL(SUM(CASE WHEN [Status] = ''VALUE_MISMATCH'' THEN CONVERT(bigint, 1) ELSE 0 END), 0) AS ValueMismatch,
        (SELECT COUNT_BIG(*) FROM #DupSource) AS DuplicateSourceKeys,
        (SELECT COUNT_BIG(*) FROM #DupTarget) AS DuplicateTargetKeys,
        @MatchedKeys AS MatchedKeys,
        @ComparedMatchedRows AS ComparedMatchedRows
    FROM #Classified;
END;';

    IF @Debug = 1
    BEGIN
        SET @Offset = 1;
        SET @Total = DATALENGTH(@Sql) / 2;
        WHILE @Offset <= @Total
        BEGIN
            PRINT SUBSTRING(@Sql, @Offset, 4000);
            SET @Offset += 4000;
        END;
    END;

    BEGIN TRY
        EXEC sys.sp_executesql
            @Sql,
            N'@IncludeMatches bit, @Output varchar(20), @TableName sysname, @MaxDetailRows int, @MaxMatchedRows int',
            @IncludeMatches = @IncludeMatches,
            @Output = @Output,
            @TableName = @SourceTable,
            @MaxDetailRows = @MaxDetailRows,
            @MaxMatchedRows = @MaxMatchedRows;
    END TRY
    BEGIN CATCH
        IF ERROR_NUMBER() IN (229, 230)
        BEGIN
            SET @Message = N'SELECT permission is required on both tables. ' + ERROR_MESSAGE();
            IF LEN(@Message) > 2048
                SET @Message = LEFT(@Message, 2045) + N'...';
            THROW 50001, @Message, 1;
        END;

        THROW;
    END CATCH;

    IF @Output = 'ALL'
        EXEC sys.sp_executesql @EmitSchemaSql;
END;
GO

/*
    History tables for the Python runner (--persist).
    compare.Run / compare.RunTable are the summary.
    Detail, duplicate, and schema rows are optional.
*/
IF SCHEMA_ID(N'compare') IS NULL
    EXEC(N'CREATE SCHEMA compare AUTHORIZATION dbo;');
GO

IF OBJECT_ID(N'compare.Run', N'U') IS NULL
BEGIN
    CREATE TABLE compare.Run (
        RunId bigint IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_compare_Run PRIMARY KEY,
        StartedAt datetime2(0) NOT NULL
            CONSTRAINT DF_compare_Run_StartedAt DEFAULT SYSDATETIME(),
        FinishedAt datetime2(0) NULL,
        ExitCode tinyint NULL,
        SourceDatabase sysname NOT NULL,
        TargetDatabase sysname NOT NULL,
        SourceServer sysname NULL,
        TargetServer sysname NULL,
        UtilityDatabase sysname NOT NULL,
        SchemaName sysname NOT NULL,
        Output varchar(20) NOT NULL,
        Preflight bit NOT NULL
            CONSTRAINT DF_compare_Run_Preflight DEFAULT (0),
        IgnoreCase bit NOT NULL
            CONSTRAINT DF_compare_Run_IgnoreCase DEFAULT (0),
        IgnoreBlank bit NOT NULL
            CONSTRAINT DF_compare_Run_IgnoreBlank DEFAULT (0),
        IncludeMatches bit NOT NULL
            CONSTRAINT DF_compare_Run_IncludeMatches DEFAULT (0),
        MaxDetailRows int NULL,
        MaxMatchedRows int NULL,
        Workers int NOT NULL
            CONSTRAINT DF_compare_Run_Workers DEFAULT (1),
        Resumed bit NOT NULL
            CONSTRAINT DF_compare_Run_Resumed DEFAULT (0),
        TablesFile nvarchar(1024) NULL,
        WorkbookPath nvarchar(1024) NULL,
        TableCount int NOT NULL
            CONSTRAINT DF_compare_Run_TableCount DEFAULT (0),
        FailedCount int NULL,
        DifferedCount int NULL,
        SkippedCount int NULL
    );

    CREATE INDEX IX_compare_Run_StartedAt
        ON compare.Run (StartedAt DESC);
END;
GO

IF COL_LENGTH(N'compare.Run', N'IgnoreBlank') IS NULL
    ALTER TABLE compare.Run ADD IgnoreBlank bit NOT NULL
        CONSTRAINT DF_compare_Run_IgnoreBlank DEFAULT (0);
GO

IF COL_LENGTH(N'compare.Run', N'MaxMatchedRows') IS NULL
    ALTER TABLE compare.Run ADD MaxMatchedRows int NULL;
GO

IF OBJECT_ID(N'compare.RunTable', N'U') IS NULL
BEGIN
    CREATE TABLE compare.RunTable (
        RunTableId bigint IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_compare_RunTable PRIMARY KEY,
        RunId bigint NOT NULL
            CONSTRAINT FK_compare_RunTable_Run
            REFERENCES compare.Run (RunId) ON DELETE CASCADE,
        GroupName nvarchar(128) NULL,
        SchemaName sysname NOT NULL,
        TableName sysname NOT NULL,
        KeyColumns nvarchar(1000) NOT NULL,
        ExcludedColumns nvarchar(max) NULL,
        Filter nvarchar(max) NULL,
        Output varchar(20) NOT NULL,
        JobStatus varchar(20) NOT NULL,
        HasDifferences varchar(20) NOT NULL,
        Skipped bit NOT NULL
            CONSTRAINT DF_compare_RunTable_Skipped DEFAULT (0),
        DurationSec decimal(10, 2) NOT NULL
            CONSTRAINT DF_compare_RunTable_DurationSec DEFAULT (0),
        SourceRowCount bigint NULL,
        TargetRowCount bigint NULL,
        CountDifference bigint NULL,
        MatchingRows bigint NULL,
        OnlyInSource bigint NULL,
        OnlyInTarget bigint NULL,
        ValueMismatch bigint NULL,
        MatchedKeys bigint NULL,
        ComparedMatchedRows bigint NULL,
        DuplicateSourceKeys bigint NULL,
        DuplicateTargetKeys bigint NULL,
        DetailRows int NOT NULL
            CONSTRAINT DF_compare_RunTable_DetailRows DEFAULT (0),
        DuplicateRows int NOT NULL
            CONSTRAINT DF_compare_RunTable_DuplicateRows DEFAULT (0),
        SchemaRows int NOT NULL
            CONSTRAINT DF_compare_RunTable_SchemaRows DEFAULT (0),
        Error nvarchar(2000) NULL,
        IncludedColumns nvarchar(max) NULL,
        ExcludePatterns nvarchar(max) NULL
    );

    CREATE INDEX IX_compare_RunTable_RunId
        ON compare.RunTable (RunId, TableName);
END;
GO

IF COL_LENGTH(N'compare.RunTable', N'IncludedColumns') IS NULL
    ALTER TABLE compare.RunTable ADD IncludedColumns nvarchar(max) NULL;
GO

IF COL_LENGTH(N'compare.RunTable', N'ExcludePatterns') IS NULL
    ALTER TABLE compare.RunTable ADD ExcludePatterns nvarchar(max) NULL;
GO

IF COL_LENGTH(N'compare.RunTable', N'MatchedKeys') IS NULL
    ALTER TABLE compare.RunTable ADD MatchedKeys bigint NULL;
GO

IF COL_LENGTH(N'compare.RunTable', N'ComparedMatchedRows') IS NULL
    ALTER TABLE compare.RunTable ADD ComparedMatchedRows bigint NULL;
GO

IF OBJECT_ID(N'compare.RunDetail', N'U') IS NULL
BEGIN
    CREATE TABLE compare.RunDetail (
        RunDetailId bigint IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_compare_RunDetail PRIMARY KEY,
        RunId bigint NOT NULL,
        RunTableId bigint NOT NULL
            CONSTRAINT FK_compare_RunDetail_RunTable
            REFERENCES compare.RunTable (RunTableId) ON DELETE CASCADE,
        BusinessKey nvarchar(max) NULL,
        Status varchar(32) NOT NULL,
        ColumnName sysname NULL,
        SourceValue nvarchar(max) NULL,
        TargetValue nvarchar(max) NULL
    );

    CREATE INDEX IX_compare_RunDetail_RunTableId
        ON compare.RunDetail (RunTableId);
    CREATE INDEX IX_compare_RunDetail_RunId
        ON compare.RunDetail (RunId);
END;
GO

IF OBJECT_ID(N'compare.RunDuplicate', N'U') IS NULL
BEGIN
    CREATE TABLE compare.RunDuplicate (
        RunDuplicateId bigint IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_compare_RunDuplicate PRIMARY KEY,
        RunId bigint NOT NULL,
        RunTableId bigint NOT NULL
            CONSTRAINT FK_compare_RunDuplicate_RunTable
            REFERENCES compare.RunTable (RunTableId) ON DELETE CASCADE,
        BusinessKey nvarchar(max) NULL,
        Status varchar(32) NOT NULL,
        RecordCount bigint NOT NULL
    );

    CREATE INDEX IX_compare_RunDuplicate_RunTableId
        ON compare.RunDuplicate (RunTableId);
    CREATE INDEX IX_compare_RunDuplicate_RunId
        ON compare.RunDuplicate (RunId);
END;
GO

IF OBJECT_ID(N'compare.RunSchema', N'U') IS NULL
BEGIN
    CREATE TABLE compare.RunSchema (
        RunSchemaId bigint IDENTITY(1, 1) NOT NULL
            CONSTRAINT PK_compare_RunSchema PRIMARY KEY,
        RunId bigint NOT NULL,
        RunTableId bigint NOT NULL
            CONSTRAINT FK_compare_RunSchema_RunTable
            REFERENCES compare.RunTable (RunTableId) ON DELETE CASCADE,
        ColumnName sysname NOT NULL,
        Side varchar(20) NOT NULL,
        Role varchar(20) NOT NULL,
        SourceType nvarchar(128) NULL,
        TargetType nvarchar(128) NULL
    );

    CREATE INDEX IX_compare_RunSchema_RunTableId
        ON compare.RunSchema (RunTableId);
    CREATE INDEX IX_compare_RunSchema_RunId
        ON compare.RunSchema (RunId);
END;
GO
