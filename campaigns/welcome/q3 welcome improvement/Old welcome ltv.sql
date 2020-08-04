select
i.*
,user_count
,n2.emails_sent as emails_sent
,n3.emails_sent as welcome_emails_sent
-- ,n4.daus as daus
-- ,n4.waus as waus
-- ,n4.maus as maus
from
(
select datediff('days', c.communication_sent_time, a.arrival_created_at) as ds_welcome_sent
, convert_timezone('America/New_York', c.communication_sent_time)::date as welcome_send_date
, case when coalesce(c.communication_vendor_template_name, outbound_communication_template_name) = 'JC_TR_ALL_Welcome_Reg' then 'ET'
       when coalesce(c.communication_vendor_template_name, outbound_communication_template_name) = 'welcome_email' then 'OCS'
       else 'Other'
       end as is_ocs
, case when substring(md5(concat('xy20',md5(c.user_key))),4,1)<'2' then 'Holdout'
       when substring(md5(concat('xy20',md5(c.user_key))),4,1)>='c' then 'Test'
       else 'Other' end as Test_group
, count (DISTINCT case when a.arrival_url NOT ilike '%onboarding-flow%' then (a.user_key + to_char(a.arrival_created_at, 'YYYYMMDDHH24') + md5(replace(replace(replace(lower(a.arrival_url),'.com/r/','.com/'),'.com/r?','.com/?'),'https://','http://'))) end) as arrivals_clean
, count(distinct a.arrival_key) as arrivals
, count(distinct ca.arrival_key) as welcome_arrivals
-- , count(distinct case when c.communication_failure_time IS NULL THEN c.communication_id END) AS emails_sent
, sum(coalesce(jcr.job_revenue, 0)) as revenue
from users u
inner join communications c
  on c.user_key = u.user_key
  and c.communication_sent_time >= convert_timezone('America/New_York', 'UTC', '2020-03-20 13:00')
  and convert_timezone('America/New_York', c.communication_sent_time)::Date != '2020-03-31'
  and convert_timezone('America/New_York', c.communication_sent_time)::Date != '2020-04-01'
  and coalesce(c.communication_vendor_template_name, c.outbound_communication_template_name) in  ('JC_TR_ALL_Welcome_Reg','welcome_email')
left join arrivals a
	on u.user_key = a.user_key
	and a.arrival_created_at >= c.communication_sent_time
	and a.arrival_created_at >= convert_timezone('America/New_York','UTC', '2020-03-20 13:00')
 	and a.arrival_computed_traffic_type in ('Email')
	and a.arrival_application = 'jobcase.com'
	and a.arrival_computed_bot_classification is null
left join dbm.communication_to_arrival ca
  on ca.user_key = c.user_key
  and ca.communication_channel = 'EMAIL'
  and ca.communication_id = c.communication_id
  and ca.communication_sent_time >= convert_timezone('America/New_York', 'UTC', '2020-03-20 13:00')
  and convert_timezone('America/New_York', ca.communication_sent_time)::Date != '2020-03-31'
  and convert_timezone('America/New_York', ca.communication_sent_time)::Date != '2020-04-01'
left join
(
SELECT user_key, arrival_key
                 , SUM(job_search_clickout_revenue) job_revenue
                 , count(distinct case when job_search_clickout_disposition = 'SUCCESS' AND job_search_clickout_status = 'POSTED' THEN job_search_clickout_key END) job_clicks
          FROM job_search_clickouts
            NATURAL JOIN arrivals
          WHERE arrival_computed_bot_classification IS NULL
          AND   arrival_application = 'jobcase.com'
          and job_search_clickout_disposition = 'SUCCESS'
                                        and job_search_clickout_status = 'POSTED'
          AND  arrival_created_at >= convert_timezone('America/New_York', 'UTC', '2020-03-20 13:00')
          GROUP BY 1,2

)
 jcr on jcr.user_key = a.user_key and jcr.arrival_key = a.arrival_key
group by 1,2,3,4
order by 1,2,3,4
)i
left join
(
select
convert_timezone('America/New_York', c.communication_sent_time)::date as welcome_send_date
, case when substring(md5(concat('xy20',md5(c.user_key))),4,1)<'2' then 'Holdout'
       when substring(md5(concat('xy20',md5(c.user_key))),4,1)>='c' then 'Test'
       else 'Other' end as Test_group
, count(distinct c.user_key) as user_count
from
communications c
where
coalesce(c.communication_vendor_template_name, c.outbound_communication_template_name) in  ('JC_TR_ALL_Welcome_Reg','welcome_email')
and communication_sent_time >= convert_timezone('America/New_York', 'UTC', '2020-03-20 13:00')
  and convert_timezone('America/New_York', communication_sent_time)::Date != '2020-03-31'
  and convert_timezone('America/New_York', communication_sent_time)::Date != '2020-04-01'
group by 1,2
)
n on n.test_group = i.test_group
and n.welcome_send_date = i.welcome_send_date
left join
(
select datediff('days', c.communication_sent_time, c2.communication_sent_time) as ds_welcome_sent
, convert_timezone('America/New_York', c.communication_sent_time)::date as welcome_send_date
, case when substring(md5(concat('xy20',md5(c.user_key))),4,1)<'2' then 'Holdout'
       when substring(md5(concat('xy20',md5(c.user_key))),4,1)>='c' then 'Test'
       else 'Other' end as Test_group
, count(distinct case when c2.communication_failure_time IS NULL THEN c2.communication_id END) AS emails_sent
from users u
inner join communications c
  on c.user_key = u.user_key
  and c.communication_sent_time >= convert_timezone('America/New_York', 'UTC', '2020-03-20 13:00')
    and convert_timezone('America/New_York', c.communication_sent_time)::Date != '2020-03-31'
  and convert_timezone('America/New_York', c.communication_sent_time)::Date != '2020-04-01'
  and coalesce(c.communication_vendor_template_name, c.outbound_communication_template_name) in  ('JC_TR_ALL_Welcome_Reg','welcome_email')
left join communications c2
	on u.user_key = c2.user_key
	and c2.communication_sent_time >= c.communication_sent_time
	and c2.communication_sent_time >= convert_timezone('America/New_York','UTC', '2020-03-20 13:00')
	  and convert_timezone('America/New_York', c2.communication_sent_time)::Date != '2020-03-31'
  and convert_timezone('America/New_York', c2.communication_sent_time)::Date != '2020-04-01'
group by 1,2,3
)
n2 on n2.test_group = i.test_group
and n2.welcome_send_date = i.welcome_send_date
and n2.ds_welcome_sent = i.ds_welcome_sent
left join
(
select datediff('days', c.communication_sent_time, c2.communication_sent_time) as ds_welcome_sent
, convert_timezone('America/New_York', c.communication_sent_time)::date as welcome_send_date
, case when substring(md5(concat('xy20',md5(c.user_key))),4,1)<'2' then 'Holdout'
       when substring(md5(concat('xy20',md5(c.user_key))),4,1)>='c' then 'Test'
       else 'Other' end as Test_group
, count(distinct case when c2.communication_failure_time IS NULL THEN c2.communication_id END) AS emails_sent
from users u
inner join communications c
  on c.user_key = u.user_key
  and c.communication_sent_time >= convert_timezone('America/New_York', 'UTC', '2020-03-20 13:00')
    and convert_timezone('America/New_York', c.communication_sent_time)::Date != '2020-03-31'
  and convert_timezone('America/New_York', c.communication_sent_time)::Date != '2020-04-01'
  and coalesce(c.communication_vendor_template_name, c.outbound_communication_template_name) in  ('JC_TR_ALL_Welcome_Reg','welcome_email')
left join communications c2
	on u.user_key = c2.user_key
	and c2.communication_sent_time = c.communication_sent_time
	and c2.communication_sent_time >= convert_timezone('America/New_York','UTC', '2020-03-20 13:00')
	  and convert_timezone('America/New_York', c2.communication_sent_time)::Date != '2020-03-31'
  and convert_timezone('America/New_York', c2.communication_sent_time)::Date != '2020-04-01'
  and coalesce(c2.communication_vendor_template_name, c2.outbound_communication_template_name) in  ('JC_TR_ALL_Welcome_Reg','welcome_email')
group by 1,2,3
)
n3 on n3.test_group = i.test_group
and n3.welcome_send_date = i.welcome_send_date
and n3.ds_welcome_sent = i.ds_welcome_sent
-- left join
-- (
-- select
-- convert_timezone('America/New_York', c.communication_sent_time)::date as welcome_send_date
-- , case when substring(md5(concat('xy20',md5(c.user_key))),4,1)<'2' then 'Holdout'
--        when substring(md5(concat('xy20',md5(c.user_key))),4,1)>='9' then 'Test'
--        else 'Other' end as Test_group
-- , count(distinct case when qmau.dau then qmau.user_key end) as daus
-- , count(distinct case when qmau.wau then qmau.user_key end) as waus
-- , count(distinct case when qmau.mau then qmau.user_key end) as maus
-- from
-- communications c
-- left join jobcase_product.qualified_active_members_historical_by_user_key qmau
-- on c.user_key = qmau.user_key
-- where
-- communication_vendor_template_name = 'JC_TR_ALL_Welcome_Reg'
-- and communication_sent_time >= convert_timezone('America/New_York', 'UTC', '2020-03-20 13:00')
--   and convert_timezone('America/New_York', c.communication_sent_time)::Date != '2020-03-31'
--   and convert_timezone('America/New_York', c.communication_sent_time)::Date != '2020-04-01'
-- group by 1,2
-- )
-- n4 on n4.test_group = i.test_group
-- and n4.welcome_send_date = i.welcome_send_date
where arrivals >0
order by 1,2,3
