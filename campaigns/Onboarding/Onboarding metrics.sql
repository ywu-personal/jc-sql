
drop table if exists #job_clickout_revenue;
create table #job_clickout_revenue distkey(user_key) as
SELECT user_key, arrival_key
                 , SUM(job_search_clickout_revenue) job_revenue
                 , count(distinct case when job_search_clickout_disposition = 'SUCCESS' AND job_search_clickout_status = 'POSTED' THEN job_search_clickout_key END) job_clicks
          FROM job_search_clickouts
            NATURAL JOIN arrivals
          WHERE arrival_computed_bot_classification IS NULL
          AND   arrival_application = 'jobcase.com'
          and job_search_clickout_disposition = 'SUCCESS'
                                        and job_search_clickout_status = 'POSTED'
          AND  arrival_created_at >= convert_timezone('America/New_York', 'UTC', '2020-06-04 00:00')
          GROUP BY 1,2
;

drop table if exists #inuvo_ad_revenue;
create table #inuvo_ad_revenue distkey(user_key) as
SELECT user_key, arrival_key
                 , SUM(revenue) ad_revenue
                 , SUM(clicks) ad_clicks
                 , SUM(bidded_searches) ad_impressions
          FROM dbm.inuvo_revenue
           NATURAL JOIN arrivals
          WHERE arrival_computed_bot_classification IS NULL
          AND   arrival_application = 'jobcase.com'
          AND   arrival_created_at >= convert_timezone('America/New_York', 'UTC', convert_timezone('America/New_York', getdate() - interval '360 days')::date)
          GROUP BY 1,2
;


select
convert_timezone('America/New_York', c.communication_sent_time)::Date AS sent_date
-- , case when substring(md5(concat('s05l26', md5(c.user_key))),7,1) < '8' then 'Control'
--        else 'Test' end as Test_group
-- , convert_timezone('America/New_York', ca.arrival_created_at)::Date as arrival_date
, count(distinct c.communication_id) AS emails_attempted
, count(distinct case when c.communication_failure_time IS NULL THEN c.communication_id END) AS emails_sent
, count(distinct case when c.communication_failure_time IS NULL AND COALESCE(c.communication_open_time_initial,c.communication_click_time_initial) IS NOT NULL THEN c.communication_id END) AS emails_opened
, count(distinct case when c.communication_failure_time IS NULL AND c.communication_click_time_initial IS NOT NULL THEN c.communication_id END) emails_clicked
, count(distinct case when c.communication_failure_time is null and (osd.email_address is not null or c.communication_unsubscribe_time_initial is not null) then c.communication_id end) emails_offer_specific_unsubscribed
, count(distinct ca.arrival_key) as arrivals
-- arrival urls
, count(distinct case when a.arrival_url ilike '%activities/welcome_messages?mm_flow=case_welcome_message_organic%' then a.arrival_key end) as Fred_arrivals
, count(distinct case when a.arrival_url ilike '%kw_rec=%' then a.arrival_key end) as recommended_kw_arrivals
, count(distinct case when a.arrival_url ilike '%profile/work-preferences/edit%' then a.arrival_key end) as edit_interest_arrivals
, count(distinct case when a.arrival_url ilike '%see_all_job=1%' then a.arrival_key end) as all_job_arrivals
, count(distinct case when a.arrival_url ilike '%search_bar=1%' then a.arrival_key end) as search_bar_arrivals
, count(distinct case when a.arrival_url ilike '%conversations/%' or a.arrival_url ilike '%jobcase.com/articles%' or a.arrival_url ilike '%jobcase.com/community/foryou%' then a.arrival_key end) as convo_arrivals
--
, sum(jcr.job_clicks)::float / count(distinct ca.arrival_key) as avg_cpa
, sum(coalesce(jcr.job_revenue, 0) + coalesce(ir.ad_revenue, 0))::float /  count(distinct ca.arrival_key) as avg_vpa
-- cpa vpa for different arrival type
, sum(case when a.arrival_url ilike '%kw_rec=%' then jcr.job_clicks end)::float / count(distinct case when a.arrival_url ilike '%kw_rec=%' then ca.arrival_key end) as kw_cpa
, sum(case when a.arrival_url ilike '%kw_rec=%' then (coalesce(jcr.job_revenue, 0) + coalesce(ir.ad_revenue, 0))::float end)  /  count(distinct case when a.arrival_url ilike '%kw_rec=%' then ca.arrival_key end) as kw_vpa
, sum(case when a.arrival_url ilike '%search_bar=1%' then jcr.job_clicks end)::float / count(distinct case when a.arrival_url ilike '%search_bar=1%' then ca.arrival_key end) as sb_cpa
, sum(case when a.arrival_url ilike '%search_bar=1%' then (coalesce(jcr.job_revenue, 0) + coalesce(ir.ad_revenue, 0))::float end)  /  count(distinct case when a.arrival_url ilike '%search_bar=1%' then ca.arrival_key end) as sb_vpa
--
, sum(jcr.job_clicks)::float as jobclicks
, sum(coalesce(jcr.job_revenue, 0)+ coalesce(ir.ad_revenue, 0)) as revenue
, arrivals/(emails_sent+0.0001) as ctr
, (revenue/emails_sent)*1000 as ecpm
, emails_clicked*1.00/emails_sent as click_rate
, emails_opened*1.00/emails_sent as open_rate
, click_rate*1.00/open_rate as click_to_open
from communications c
left join dbm.communication_to_arrival ca
  on ca.user_key = c.user_key
  and ca.communication_channel = 'EMAIL'
  and ca.communication_id = c.communication_id
  and ca.communication_sent_time >= convert_timezone('America/New_York', 'UTC', '2020-06-04 15:30')
left join arrivals a
  on a.user_key = ca.user_key and a.arrival_key = ca.arrival_key
left join
(
    select distinct sendid || '_' || batchid as email_batch_id
    , emailaddress as email_address
    from dbm.jobcase_preferences
    where  option_id  in ('3','4')
) osd on c.communication_to_address = osd.email_address and c.bulk_send_id = osd.email_batch_id
left join #job_clickout_revenue jcr on jcr.user_key = ca.user_key and jcr.arrival_key = ca.arrival_key
left join #inuvo_ad_revenue ir on ir.user_key = a.user_key and ir.arrival_key = a.arrival_key

where
c.communication_sending_domain IN ('jobcase.com','post.jobcase.com','t.jobcase.com', 'umail.jobcase.com', 'tumail.jobcase.com')
and c.communication_sent_time >= convert_timezone('America/New_York', 'UTC', '2020-06-04 15:30') and c.communication_sent_time <= convert_timezone('America/New_York', 'UTC', '2020-06-05 18:30')
AND c.communication_vendor_template_name in ('JC_ALL_Onboarding_v2')
-- and jr.rk = arrival_listing
-- and arrival_listing in ('1','2','3','4')
group by 1
order by 1
;
