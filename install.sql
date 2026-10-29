CREATE VIEW dbo.trans_view AS
SELECT
    trans.TRANS_SRGT,
    p.POLICY_BK,
    wrks.WRKS_BK,
    clm.CLA_BK,
    brk.BROK_BK,
    trans.TRANS_AUDIT_DATE_SRGT,
    trans.TRANS_PROCESSING_PERIOD_SRGT,
    trans.TRANS_ACCOUNTING_TO_DATE_SRGT,
    trans.TRANS_ACCOUNTING_FROM_DATE_SRGT,
    trans.TRANS_BASE_GROSS_AMT,
    trans.TRANS_BASE2_GROSS_AMT,
    trans.TRANS_SETT_GROSS_AMT,
    trans.TRANS_ORIG_GROSS_AMT,
    ocurr.CURR_BK AS originCurrency,
    scurr.CURR_BK AS settCurrency,
    bcurr.CURR_BK AS baseCurrency,
    usr.USR_LOGIN
FROM [HO_DW_UAT].[SaudiRe_DW].[dbo].[FACT_IW_TRANSACTION] AS trans

LEFT JOIN [HO_DW_UAT].[SaudiRe_DW].[dbo].[DIM_POLICY] AS p
    ON trans.POLICY_SRGT = p.POLICY_SRGT

LEFT JOIN [HO_DW_UAT].[SaudiRe_DW].[dbo].[DIM_WORK_SHEET] AS wrks
    ON wrks.WRKS_SRGT = trans.TRANS_SRGT

LEFT JOIN [HO_DW_UAT].[SaudiRe_DW].[dbo].[DIM_CLAIM] AS clm
    ON clm.CLA_CLAIM_SRGT = trans.TRANS_SRGT

LEFT JOIN [HO_DW_UAT].[SaudiRe_DW].[dbo].[DIM_BROKER] AS brk
    ON brk.BROK_SRGT = trans.BROK_SRGT

LEFT JOIN [HO_DW_UAT].[SaudiRe_DW].[dbo].[DIM_CURRENCY] AS ocurr
    ON trans.CURR_ORIG_SRGT = ocurr.CURR_SRGT

LEFT JOIN [HO_DW_UAT].[SaudiRe_DW].[dbo].[DIM_CURRENCY] AS scurr
    ON trans.CURR_SETT_SRGT = scurr.CURR_SRGT

LEFT JOIN [HO_DW_UAT].[SaudiRe_DW].[dbo].[DIM_CURRENCY] AS bcurr
    ON trans.CURR_BASE_SRGT = bcurr.CURR_SRGT

LEFT JOIN [HO_DW_UAT].[SaudiRe_DW].[dbo].[DIM_SYN_USER] AS usr
    ON trans.USR_SRGT = usr.USR_SRGT

WHERE clm.CLA_BK IS NOT NULL
  AND wrks.WRKS_BK IS NOT NULL;
