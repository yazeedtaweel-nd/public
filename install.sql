 create view trans_view as
select trans.TRANS_SRGT, p.POLICY_BK, wrks.WRKS_BK, clm.CLA_BK, brk.BROK_BK, trans.TRANS_AUDIT_DATE_SRGT, trans.TRANS_PROCESSING_PERIOD_SRGT,
       trans.TRANS_ACCOUNTING_TO_DATE_SRGT,trans.TRANS_ACCOUNTING_FROM_DATE_SRGT, trans.TRANS_BASE_GROSS_AMT, trans.TRANS_BASE2_GROSS_AMT, trans.TRANS_SETT_GROSS_AMT,
       trans.TRANS_ORIG_GROSS_AMT, ocurr.CURR_BK as originCurrency, scurr.CURR_BK as settCurrency, bcurr.CURR_BK as baseCurrency, usr.USR_LOGIN
from FACT_IW_TRANSACTION as trans
left join DIM_POLICY as p
on trans.POLICY_SRGT = p.POLICY_SRGT

left join DIM_WORK_SHEET as wrks
on wrks.WRKS_SRGT = trans.TRANS_SRGT
left join DIM_CLAIM as clm
on clm.CLA_CLAIM_SRGT = trans.TRANS_SRGT
left join dim_broker as brk
on brk.BROK_SRGT = trans.BROK_SRGT
left join DIM_CURRENCY as ocurr
on trans.CURR_ORIG_SRGT = ocurr.CURR_SRGT
left join DIM_CURRENCY as scurr
on trans.CURR_ORIG_SRGT = scurr.CURR_SRGT
left join DIM_CURRENCY as bcurr
on trans.CURR_ORIG_SRGT = bcurr.CURR_SRGT
left join DIM_SYN_USER as usr
on trans.USR_SRGT = usr.USR_SRGT

where cla_bk is not null and wrks_bk is not null
