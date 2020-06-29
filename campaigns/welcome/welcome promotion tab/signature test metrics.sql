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
          AND  arrival_created_at >= convert_timezone('America/New_York', 'UTC', '2020-05-20 19:10')
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


-- Welcome reg EToOnb metrics

select
convert_timezone('America/New_York', c.communication_sent_time)::Date AS sent_date
, case when (convert_timezone('America/New_York', c.communication_sent_time) < '2020-06-05 11:25' and substring(md5(concat('signAture', md5(c.user_key))),5,1) < 'c')
        or (convert_timezone('America/New_York', c.communication_sent_time) >= '2020-06-05 11:25' and substring(md5(concat('signAture', md5(c.user_key))),5,1) < '8') then 'Control'
       else 'Test' end as Test_group
, case when communication_to_address_email_domain_group in ('GMAIL', 'YAHOO', 'AOL', 'MSN') then communication_to_address_email_domain_group else 'OTHER' END AS DOMAIN_GROUP
, count(distinct c.communication_id) AS emails_attempted
, count(distinct case when c.communication_failure_time IS NULL THEN c.communication_id END) AS emails_sent
, count(distinct case when c.communication_failure_time IS NULL AND COALESCE(c.communication_open_time_initial,c.communication_click_time_initial) IS NOT NULL THEN c.communication_id END) AS emails_opened
, count(distinct case when c.communication_failure_time IS NULL AND c.communication_click_time_initial IS NOT NULL THEN c.communication_id END) emails_clicked
, count(distinct case when c.communication_failure_time is null and (osd.email_address is not null or c.communication_unsubscribe_time_initial is not null) then c.communication_id end) emails_offer_specific_unsubscribed
, count(distinct ca.arrival_key) as arrivals
, sum(jcr.job_clicks)::float / count(distinct ca.arrival_key) as cpa
-- , sum(case when a.arrival_url ilike '%listing%check%' then jcr.job_clicks end)::float / (count(distinct case when a.arrival_url ilike '%listing%check%' then a.arrival_key end)+.00001) as cpa_job_listing
-- , sum(case when a.arrival_url ilike '%jobs/result%' then jcr.job_clicks end)::float / (count(distinct case when a.arrival_url ilike '%jobs/result%' then a.arrival_key end)+.00001) as cpa_job_search
, sum(coalesce(jcr.job_revenue, 0) + coalesce(ir.ad_revenue, 0))::float /  count(distinct ca.arrival_key) as vpa
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
  and ca.communication_sent_time >= convert_timezone('America/New_York', 'UTC', '2020-05-20 19:10')
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
and c.communication_sent_time >= convert_timezone('America/New_York', 'UTC', '2020-05-20 19:10')
AND c.communication_vendor_template_name in ('JC_TR_ALL_Welcome_Reg')
-- and communication_to_address_email_domain_group  = 'GMAIL'
-- and jr.rk = arrival_listing
-- and arrival_listing in ('1','2','3','4')
group by 1,3,2
order by 1,3,2
;
