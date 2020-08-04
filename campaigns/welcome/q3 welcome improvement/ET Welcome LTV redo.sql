
select i.*
, n1.welcome_arrivals
, n.user_count as user_count
, n2.other_emails_sent
from
(
select
datediff('days', su.sent_date, convert_timezone('America/New_York', a.arrival_created_at)::Date) as ds_first_send
, su.sent_date
, su.Test_group
, count(distinct a.arrival_key) as arrivals
, sum(coalesce(jcr.job_revenue, 0)) as revenue
from #welcome_record su
left join arrivals a
   on a.user_key = su.user_key
   and convert_timezone('America/New_York', a.arrival_created_at)::Date >= su.sent_date
 	 and a.arrival_computed_traffic_type in ('Email')
	 and a.arrival_application = 'jobcase.com'
	 and a.arrival_computed_bot_classification is null
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
  ) jcr
  on jcr.user_key = su.user_key and jcr.arrival_key = a.arrival_key
group by 1,2,3
) i
left join
  (
    select
    su.sent_date as sent_date
    , su.Test_group as Test_group
    , count(distinct su.user_key) as user_count
    from
    #welcome_record su
    group by 1,2
  ) n
  on n.sent_date = i.sent_date and n.Test_group = i.Test_group
left join
  (
   select
   datediff('days', su.sent_date, convert_timezone('America/New_York', ca.arrival_created_at)::Date) as ds_first_send
   , su.sent_date
   , su.Test_group
   , count(distinct ca.arrival_key) as welcome_arrivals
   from #welcome_record su
   left join communications c
     on su.user_key = c.user_key
     and convert_timezone('America/New_York', c.communication_sent_time)::Date >= su.sent_date
     and coalesce(outbound_communication_template_name,c.communication_vendor_template_name) in ('JC_TR_ALL_Welcome_Reg')
   left join dbm.communication_to_arrival ca
     on ca.user_key = c.user_key
     and ca.communication_channel = 'EMAIL'
     and ca.communication_id = c.communication_id
     group by 1,2,3
  ) n1
  on n1.sent_date = i.sent_date
  and n1.Test_group = i.Test_group
  and n1.ds_first_send = i.ds_first_send
left join
  (
   select
   datediff('days', su.sent_date, convert_timezone('America/New_York', c2.communication_sent_time)::Date) as ds_first_send
   , su.sent_date
   , su.Test_group
   , count(distinct case when c2.communication_failure_time is null then c2.communication_id end) as other_emails_sent
   from #welcome_record su
--    left join communications c
--      on c.user_key = su.user_key
--      and c.communication_sent_time >= convert_timezone('America/New_York', 'UTC', '2020-06-04 15:10')
--      and convert_timezone('America/New_York', c.communication_sent_time)::Date = su.sent_date
--      and c.communication_vendor_template_name = 'JC_ALL_Onboarding_v2'
   left join communications c2
     on su.user_key = c2.user_key
--      and c2.communication_sent_time >= convert_timezone('America/New_York', 'UTC', '2020-06-04 15:10')
     and convert_timezone('America/New_York', c2.communication_sent_time)::Date >= su.sent_date
     and coalesce(c2.outbound_communication_template_name,c2.communication_vendor_template_name) not in ('JC_TR_ALL_Welcome_Reg')
   group by 1,2,3
  ) n2
  on n2.sent_date = i.sent_date
  and n2.Test_group = i.Test_group
  and n2.ds_first_send = i.ds_first_send
where arrivals >0
order by 1,2,3
;
