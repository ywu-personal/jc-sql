
-- create coverage table
drop table if exists #coverage3;
create table #coverage3 as
select
arrival_key
, user_key
, job_search_query
, job_search_location
, avg(match) as avg_match
from
(
select
arrival_key
, user_key
, job_search_query
, job_search_location
, job_Search_key
, CASE WHEN count(DISTINCT CASE WHEN job_search_impression_job_title ILIKE '%' || job_search_query || '%'
OR job_search_impression_company_name ILIKE '%' || job_search_query || '%'
OR job_search_query ILIKE '%' || job_search_impression_company_name || '%'
OR job_search_query ILIKE '%' || job_search_impression_job_title || '%'
THEN job_search_key END) = 0 THEN 0 ELSE 1 END AS match
FROM job_searches
Natural join job_search_impressions
natural join arrivals
where job_search_created_at >=  convert_timezone('America/New_York', 'UTC', '2020-06-20 00:00')
	and arrival_computed_traffic_type = 'Email'
  and arrival_url ilike '%confirm_email=true%jb_q%'
  and job_search_key is not null
  and job_search_limit = 4
  and job_search_application_display_path = '/#foryou'
  and job_search_query is not null
group by 1,2,3,4,5
)
group by 1,2,3,4
;

-- kw match pct by group

select
convert_timezone('America/New_York', c.communication_sent_time)::Date AS sent_date
, case when c.communication_vendor_template_name = 'JC_TR_ALL_Welcome_Reg' then 'ET'
       when c.outbound_communication_template_name = 'welcome_email' then 'OCS' end as is_ocs
, case when communication_to_address_email_domain_group in ('GMAIL') then communication_to_address_email_domain_group else 'NON-GMAIL' END AS DOMAIN_GROUP
, case when er2.arrival_domain = 'jobcase.com' then 'JC' else 'JCN' end as arrival_domain
, count(distinct c.communication_id) AS emails_attempted
, count(distinct case when c.communication_failure_time IS NULL THEN c.communication_id END) AS emails_sent
, count(distinct case when c.communication_failure_time IS NOT NULL THEN c.communication_id END) AS emails_failure
, count (distinct c.user_key) as recipients
, count(distinct case when c.communication_failure_time IS NULL AND COALESCE(c.communication_open_time_initial,c.communication_click_time_initial) IS NOT NULL THEN c.communication_id END) AS emails_opened
, count(distinct case when c.communication_failure_time IS NULL AND c.communication_click_time_initial IS NOT NULL THEN c.communication_id END) emails_clicked
, count(distinct case when c.communication_failure_time is null and (osd.email_address is not null or c.communication_unsubscribe_time_initial is not null) then c.communication_id end) emails_offer_specific_unsubscribed
, count(distinct ca.arrival_key) as arrivals
, count(distinct case when a.arrival_url ilike '%confirm_email=true%' and a.arrival_url ilike '%jb_q%' then ca.arrival_key end) as for_you_arrivals
, count(distinct case when avg_match > 0 then ca.arrival_key end) as has_match
, count(distinct case when avg_match = 0 then ca.arrival_key end) as no_match
, count(distinct case when job_search_query is null and  a.arrival_url ilike '%confirm_email=true%' and a.arrival_url ilike '%jb_q%' then ca.arrival_key end) as null_match
, has_match/(has_match+no_match+0.0001) as pct_arrival_match
from communications c
inner join
  (
  select
  distinct user_key
  ,arrival_created_at
  ,arrival_domain
  from event_registrations
  natural join arrivals
  where arrival_created_at >= convert_timezone('America/New_York', 'UTC', '2020-07-01 00:00')
  and arrival_computed_traffic_source <> 'Percipio Email'
  )er2 on er2.user_key = c.user_key
  and er2.arrival_created_at >= c.communication_sent_time - interval '30 minutes'
  and er2.arrival_created_at <= c.communication_sent_time
left join dbm.communication_to_arrival ca
  on ca.user_key = c.user_key
  and ca.communication_channel = 'EMAIL'
  and ca.communication_id = c.communication_id
  and ca.communication_sent_time >= convert_timezone('America/New_York', 'UTC', '2020-07-01 00:00')
left join
(
    select distinct sendid || '_' || batchid as email_batch_id
    , emailaddress as email_address
    from dbm.jobcase_preferences
    where  option_id  in ('3','4')
) osd on c.communication_to_address = osd.email_address and c.bulk_send_id = osd.email_batch_id
left join arrivals a on a.user_key = ca.user_key and a.arrival_key = ca.arrival_key
left join #coverage3 cv on cv.arrival_key = a.arrival_key and cv.user_key = a.user_key and job_search_query = f_url_param_utf8(a.arrival_url,'jb_q')
where
c.communication_sending_domain IN ('jobcase.com','post.jobcase.com','t.jobcase.com', 'umail.jobcase.com', 'tumail.jobcase.com')
and c.communication_sent_time >= convert_timezone('America/New_York', 'UTC', '2020-07-01 00:00')
and coalesce(outbound_communication_template_name,c.communication_vendor_template_name) in ('welcome_email','JC_TR_ALL_Welcome_Reg')
group by 1,2,3,4
order by 1,2,3,4
;

-- welcome kw by users
