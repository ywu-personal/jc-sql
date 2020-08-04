/*REENGAGEMENT QUERY*/
-- select * from dbm.jes_email_requests;

/*
#reengage_ids
Select campaign_id's for jobs that are special reengagement promotion (type = 0) that are to be promoted TODAY
The special_promotion_variable is selected as the event_campaign_id so it can be linked to the event
*/

drop table if exists #reengage_ids;
create table #reengage_ids as
  select
  campaign_id
--   , '5646894' as event_campaign_id -- for specific event campaign
  , special_promotion_variable as event_campaign_id
  from dbm.jes_email_requests
  where email_target_send_date = getdate()::date
--   where email_target_send_date = '2019-01-15' --for specific send date
  and campaign_id not in (select distinct campaign_id from dbm.jc_jes_jobs_campaign_details_record)
  and is_live = '1'
  and employer_status = 'APPROVED'
  and display_approval_status = 'APPROVED'
  and special_promotion = '1'
  and special_promotion_type = 'REENGAGEMENT'

  and canceled != 1
  and date_part('weekday',getdate()) <5;

select * from #reengage_ids;

/*
#jobs
Select the details for the jobs table that will be used for the send record and the campaign details
*/

drop table if exists #jobs;
create table #jobs as
  select
    campaign_id
    , employer_name
    , convert_timezone('America/New_York', getdate())::date as send_date
    , convert_timezone('America/New_York', getdate()) as pull_time
    , job_title
    , job_city
    , job_state
    , job_zip
    , posting_key --reengagement should use posting_key
    , ('https://jobcase.com/jobs/'|| posting_key || '/listing-check?iframe=false') as job_url
    , 1.0 as job_rk
    , special_promotion
    , special_promotion_type
    , 1 as campaign_version
    , special_promotion_variable
    , wage
  from dbm.jes_email_requests -- jes
  where campaign_id in (select campaign_id from #reengage_ids);

select * from #jobs;


/*
dbm.jc_jes_jobs_campaign_details_record
Select all the info from the #jobs table to insert into the campaign_details. Should not have overlap...
*/

-- drop table if exists dbm.jc_jes_jobs_campaign_details_record;
-- create table dbm.jc_jes_jobs_campaign_details_record
-- (
--     campaign_id varchar(255)
--     , employer_name varchar(255)
--     , send_date date
--     , pull_time timestamp
--     , job_title varchar(255)
--     , job_city varchar(255)
--     , job_state varchar(3)
--     , job_zip varchar(5)
--     , posting_key varchar(255)
--     , job_url varchar(2000)
--     , job_rk bigint
-- , special_promotion varchar(255)
-- , special_promotion_type varchar(255)
--
-- ) distkey(campaign_id) sortkey(send_date, pull_time);
--  grant select on dbm.jc_jes_jobs_campaign_details_record to public;
--  grant all on dbm.jc_jes_jobs_campaign_details_record to dalfonso, listgen, rebecca;



delete from dbm.jc_jes_jobs_campaign_details_record
where pull_time >= date_add('minute',-10, convert_timezone('America/New_York', getdate()))
;

insert into dbm.jc_jes_jobs_campaign_details_record
select * from #jobs
;

--check to see it's all there!
select * from dbm.jc_jes_jobs_campaign_details_record
where pull_time >= date_add('minute',-10, convert_timezone('America/New_York', getdate()))
;



/*
#event_users
Select for users who received the event promotion email based on the event_campaign_id
using the EVENTS_SEND_RECORD, which records the date the information is pulled as the send date
make sure that the event date and the send date are correct. if the number does not seem right, it's possible the send may have happened on a different day
*/

drop table if exists #event_users;
create table #event_users as
(select user_key
, campaign_id as event_campaign_id
, send_date
, employer_name
from dbm.jc_jes_events_send_record
where event_campaign_id in (select event_campaign_id from #reengage_ids) --select the campaign_ids for re-selection
and len(event_campaign_id) = 7
)
UNION
(select user_key
, campaign_id as event_campaign_id
, send_date
, employer_name
from dbm.jc_jes_jobs_email_send_record
where event_campaign_id in (select event_campaign_id from #reengage_ids) --select the campaign_ids for re-selection
and len(event_campaign_id) = 6
)
;

--double check your counts!
select count(user_key), count(distinct user_key) from #event_users;

/*
#engaged_users
these are the users that are shown to have opened or clicked the corresponding event email
*/
drop table if exists #engaged_users;
create table #engaged_users as

select
distinct eu.user_key as user_key
, employer_name
from communications c
join #event_users eu on eu.user_key = c.user_key
where
c.communication_sent_time::date = eu.send_date::date
and (c.communication_vendor_template_name ilike '%MS\\_JOB\\_%event%' )
and (c.communication_open_time_initial is not null or c.communication_click_time_initial is not null)
and len(eu.event_campaign_id) = 7
group by 1,2
;

Insert into #engaged_users
(
  select
  distinct eu.user_key as user_key
  , eu.employer_name
  from communications c
  join #event_users eu on eu.user_key = c.user_key
  left join #engaged_users l on l.user_key = c.user_key
  where
  c.communication_sent_time::date = eu.send_date::date
  and (c.communication_vendor_template_name ilike '%MS\\_JOB\\_%virtual%' )
  and (c.communication_open_time_initial is not null or c.communication_click_time_initial is not null)
  and len(eu.event_campaign_id) = 6
  and l.user_key is null -- exclude anyone already receiving a send
  group by 1,2
)
;

--check your counts. here you're checking the users by company that are eligible to receive the reengagement campaign based on their interest
select employer_name, count(distinct user_key), count(user_key) from #engaged_users
group by 1;
-- select * from #engaged_users;

/*
#audience
everyone's favorite part!
connecting users within 50 miles. this is a reengagement campaign so there is no cap volume due to the small size
and the fact that it cannot be larger than the event send volume
*/


drop table if exists #audience;
create table #audience distkey(user_key) as
select distinct cc.user_key
, first_value(z.campaign_id) over(partition by cc.user_key order by random() rows unbounded preceding) as campaign_id

from dbm.jobcase_email_content_cadence cc
inner join users u on cc.user_key = u.user_key
inner join
(
  select distinct a.zipcode2, e.campaign_id, e.employer_name
  from mart.zip_to_zip_within_50m_distances a
  inner join
  (
    select distinct job_zip, campaign_id, employer_name
    from dbm.jc_jes_jobs_campaign_details_record
    where campaign_id in (select campaign_id from #reengage_ids)
  ) e on e.job_zip = a.zipcode
 where (
      a.distance < 50
   )
) z on z.zipcode2 = substring(u.user_entered_zip_code,1,5)
left join dbm.jc_jes_jobs_email_send_record r
  on r.user_key = cc.user_key
  and r.send_date = getdate()::date
left join dbm.jc_jes_jobs_email_send_record r1
  on r1.user_key = cc.user_key
  and r1.employer_name = z.employer_name
  and r1.send_date >= convert_timezone('America/New_York', getdate())::date - interval '3 days'
left join dbm.jc_jes_events_send_record r2
  on r2.user_key = cc.user_key
  and r2.send_date = convert_timezone('America/New_York', getdate())::date

where true
and cc.send_date = getdate()::date
and cc.sending_grouping = 'JOBCASE'
and cc.content_type in ('Company', 'JobAlert', 'Standard')

and cc.user_key in
(select distinct user_key from #engaged_users)

and cc.user_entered_email not in
(
  select distinct emailaddress
  from dbm.jobcase_preferences
  where offer_id in ('1', '15', '22', '26', '27', '36', '42', '43', '45', '60', '69', '72', '80','127', '132')
)
and r.user_key is null -- don't send jes jobs more than once to a member in a day
and r1.user_key is null -- don't send if user received jes jobs send for same employer in last 3 days
and r2.user_key is null -- don't send if user received event send today
;

--check numbers :)
select campaign_id, count(distinct user_key), count(user_key) from #audience
group by 1;



/*
dbm.jc_jes_jobs_email_send_record
make sure you're inserting into the right table
this table compiles are the user_key's fronm the #audience that will be sent to along with the campaign_id and employer_name.
Joins to #jobs on campaign_id
*/
-- drop table if exists dbm.jc_jes_jobs_email_send_record;
-- create table dbm.jc_jes_jobs_email_send_record
-- (
--   user_key varchar(255)
--   , send_date date
--   , pull_time timestamp
--   , campaign_id varchar(255)
--   , employer_name varchar(255)
--   , campaign_version varchar(255)
-- )
--
-- distkey(user_key) sortkey(send_date, pull_time);
-- grant select on dbm.jc_jes_jobs_email_send_record to public;
-- grant all on dbm.jc_jes_jobs_email_send_record to dalfonso, listgen, rebecca;


-- truncate dbm.jc_jes_jobs_email_send_record;

delete from dbm.jc_jes_jobs_email_send_record
where pull_time >= date_add('minute',-10, convert_timezone('America/New_York', getdate()));

insert into dbm.jc_jes_jobs_email_send_record
  select
  user_key
  , convert_timezone('America/New_York', getdate())::date as send_date
  , convert_timezone('America/New_York', getdate()) as pull_time
  , a.campaign_id
  , j.employer_name
  , '1' as campaign_version --test this

  from #audience a
  join #jobs j on j.campaign_id = a.campaign_id
  ;

--check counts by campaign_id and employer_name
select campaign_id, employer_name, count(distinct user_key), count(user_key) from dbm.jc_jes_jobs_email_send_record
where pull_time >= date_add('minute',-10, convert_timezone('America/New_York', getdate()))
group by 1,2;




/*STANDARD JOBS QUERY*/
-- select * from dbm.jes_email_requests;

/*
#resend_ids
Select campaign_id's for campaigns that have been sent at least once but have not yet met a total #sends of 90% max volume.
Campaigns can only be selected once the requisite number of days, as set by the email_frequency, have passed.
This does not select campaigns that are reengagement or custom, but makes space for standard and other requests where the
audience can be generated using the zipcode of the job (or target zipcode).

*/

drop table if exists #resend_ids;

create table #resend_ids as
select distinct campaign_id from
(    select distinct r.campaign_id as campaign_id
, max(convert(int, r.campaign_version)) as max_campaign_version
, max(r.send_date) as last_send
, max(j.email_frequency) as email_frequency
, DATEADD('day', max(convert(int, j.email_frequency)), max(r.send_date::date)) as next_send_date
, count(r.user_key)


from dbm.jc_jes_jobs_email_send_record r
join dbm.jes_email_requests j on j.campaign_id = r.campaign_id

    where
((j.special_promotion = '1' and j.special_promotion_type in ('BRANDING', 'VIRTUAL_HIRING_EVENT') )
  OR j.special_promotion = '0')
    and j.canceled != 1
    and is_live = 1
    and j.email_target_volume is not null
    and employer_status = 'APPROVED'
    and display_approval_status = 'APPROVED'
    and r.campaign_id not in (select campaign_id from dbm.jc_jes_jobs_campaign_details_record where send_date = getdate()::date)
group by 1
    having (next_send_date <= getdate()::date )
    and max(r.campaign_version::float) < max(j.email_max_publish::float)
    and count(r.user_key) <= (0.9 * max(j.email_target_volume))
    and date_part('weekday',getdate()) < 6 --dont select ids on Sat, Sun
)
;


select * from #resend_ids;


drop table if exists #promo_ids;
create table #promo_ids as
  select
  campaign_id
--   , '5646894' as event_campaign_id -- for specific event campaign
  from dbm.jes_email_requests
  where email_target_send_date >= getdate()::date - 7
  and email_target_send_date::date <= case when special_promotion_type = 'VIRTUAL_HIRING_EVENT' THEN getdate()::date
                                     when special_promotion_type = 'BRANDING' THEN getdate()::date
                                     when special_promotion_type is null THEN DATEADD(DAY, 3, getdate())::date
                                     END
  and campaign_id not in (select campaign_id from dbm.jc_jes_jobs_campaign_details_record)
--   where email_target_send_date = '2019-01-17' --for specific send date
  and is_live = '1'
  and employer_status = 'APPROVED'
  and display_approval_status = 'APPROVED'
  and ((special_promotion = '1' and special_promotion_type in ('BRANDING', 'VIRTUAL_HIRING_EVENT') )
  OR special_promotion = '0')
  and canceled != 1
  -- and event_campaign_id != '537054'
--   and date_part('weekday',getdate()) < 6
union
select campaign_id from #resend_ids

;

select * from #promo_ids;


drop table if exists #campaign_versions;
create table #campaign_versions as
select p.campaign_id
, case
    when p.campaign_id not in (select campaign_id from dbm.jc_jes_jobs_campaign_details_record) THEN '0'
    ELSE (count(distinct send_date)) END as campaigns_sent
, case
    when p.campaign_id not in (select campaign_id from dbm.jc_jes_jobs_campaign_details_record) THEN '1'
    ELSE (count(distinct send_date) + 1) END as campaign_version
from dbm.jc_jes_jobs_campaign_details_record r
right join #promo_ids p on p.campaign_id = r.campaign_id
where p.campaign_id in (select campaign_id from #promo_ids)
group by 1;
select * from #campaign_versions;


drop table if exists #jobs;
create table #jobs as
  select
    j.campaign_id
    , employer_name
    , convert_timezone('America/New_York', getdate())::date as send_date
    , convert_timezone('America/New_York', getdate()) as pull_time
    , job_title
    , job_city
    , job_state
    , job_zip
    , posting_key --reengagement should use posting_key
    , ('https://jobcase.com/jobs/'|| posting_key || '/listing-check?iframe=false') as job_url
    , 1.0 as job_rk
    , special_promotion
    , special_promotion_type
    , c.campaign_version
    , special_promotion_variable
    , wage
  from dbm.jes_email_requests j
  join #campaign_versions c on j.campaign_id = c.campaign_id
  where j.campaign_id in (select campaign_id from #promo_ids);

select * from #jobs;


--delete section commented out but just in case you need it. check lookback window

-- delete from dbm.jc_jes_jobs_campaign_details_record
-- where pull_time >= date_add('minute',-10, convert_timezone('America/New_York', getdate()))
-- ;



insert into dbm.jc_jes_jobs_campaign_details_record
select * from #jobs
;

--check to see it's all there!
select * from dbm.jc_jes_jobs_campaign_details_record
where pull_time >= date_add('minute',-10, convert_timezone('America/New_York', getdate()))
;
--


drop table if exists #campaign_priority;
create table #campaign_priority as
  select distinct (j.campaign_id)
        , max(j.email_target_volume) as email_target_volume
        , count(r.user_key) as emails_sent
        , case when convert(int,max(r.campaign_version)) is null then convert(int,max(j.email_max_publish)) else convert(int, (max(j.email_max_publish) - max(r.campaign_version))) end as sends_left
        , (max(j.email_target_volume) - count(r.user_key)) as sends_diff
        , case when max(r.campaign_version) is null then (sends_diff/(max(j.email_max_publish))) ELSE sends_diff/sends_left END send_priority

from dbm.jes_email_requests j
left join dbm.jc_jes_jobs_email_send_record r on r.campaign_id = j.campaign_id
where j.campaign_id in (select campaign_id from #promo_ids)
group by 1
;
select * from #campaign_priority;


drop table if exists #id_rk;
create table #id_rk as
select campaign_id,
send_priority,
rank() over( order by send_priority desc, random()) as campaign_rk
-- dense_rank() over( order by send_priority desc) as campaign_rk_2,
-- row_number() over( order by send_priority desc) as campaign_rk_3


from #campaign_priority

;

select * from #id_rk;

drop table if exists #audience;
create table #audience distkey(user_key) as
select distinct cc.user_key
, first_value(z.campaign_id) over(partition by cc.user_key order by random() rows unbounded preceding) as campaign_id

from dbm.jobcase_email_content_cadence cc
inner join users u on u.user_key = cc.user_key
inner join
(
  select distinct a.zipcode2, e.campaign_id, e.campaign_rk, e.employer_name, e.send_priority
  from mart.zip_to_zip_within_50m_distances a
  inner join
  (
    select distinct job_zip, r.campaign_id, r.employer_name, i.send_priority, i.campaign_rk as campaign_rk
    from dbm.jc_jes_jobs_campaign_details_record r
    left join #id_rk i on i.campaign_id = r.campaign_id
    where r.campaign_id in (select campaign_id from #promo_ids)
  ) e on e.job_zip = a.zipcode
 where (
      a.distance < 30
   )
) z on z.zipcode2 = substring(u.user_entered_zip_code,1,5)
left join dbm.jc_jes_jobs_email_send_record r on r.user_key = cc.user_key
  and r.send_date = convert_timezone('America/New_York', getdate())::date
left join (
          select s.user_key
          , s.employer_name
          , s.send_date
          , c.special_promotion
          , c.special_promotion_type
          from dbm.jc_jes_jobs_email_send_record s join dbm.jc_jes_jobs_campaign_details_record c on s.campaign_id = c.campaign_id and s.send_date = c.send_date
        ) r1 on r1.user_key = cc.user_key
            and r1.employer_name = z.employer_name
            and r1.send_date >= convert_timezone('America/New_York', getdate())::date - interval '3 days'
            and (r1.special_promotion = '1' and r1.special_promotion_type in ('BRANDING', 'VIRTUAL_HIRING_EVENT'))


where true
and cc.send_date = getdate()::date
and cc.sending_grouping = 'JOBCASE'
and cc.content_type in ('Company', 'JobAlert', 'Standard')

and
(
  (
    cc.cadence_email_domain_group in ('GMAIL', 'MSN')
    and cc.user_key IN
    (
      SELECT DISTINCT user_key
      FROM communications
      WHERE communication_channel = 'EMAIL'
      AND (communication_open_time_latest >= getdate() - INTERVAL '20 days'
      OR communication_click_time_latest >= getdate() - INTERVAL '20 days')
    )
    and cc.tplus_type not in ('tp-dslr-ne-', 'tp-dslrr-ne-')
  )
  or cc.cadence_email_domain_group not in ('GMAIL', 'MSN')
  or cc.cadence_email_domain_group is null
)
and cc.tplus_type != 'tp-wb-dslr-'

and cc.user_entered_email not in
(
  select distinct emailaddress
  from dbm.jobcase_preferences
  where offer_id in ('1', '15', '22', '26', '27', '36', '42', '43', '45', '60', '69', '72', '80','127', '132')
)
and r.user_key is null -- don't send jes jobs more than once to a member in a day
and r1.user_key is null -- don't send if user received branding or VHE send for same employer in last 3 days


;

select campaign_id, count(distinct user_key), count(user_key) from #audience
group by 1;


DROP TABLE IF EXISTS #campaigns_too_small;
CREATE TEMP TABLE #campaigns_too_small AS
SELECT
campaign_id
,count(DISTINCT user_key) user_count
FROM
#audience
GROUP BY 1
HAVING user_count <10000
;

-- ensure all UHG May 2020 custom brand boosts use 50 mile radius
INSERT INTO #campaigns_too_small
SELECT
campaign_id
, COUNT(DISTINCT user_key) user_count
FROM
#audience
WHERE TRUE
AND campaign_id IN
(
 '537335', '537336',
 '537337', '537338',
 '537339', '537340',
 '537341', '537342',
 '537343', '537344',
 '537345', '537346',
 '537347', '537348'
)
GROUP BY 1
;

SELECT * FROM #campaigns_too_small;


drop table if exists #audience;
create table #audience distkey(user_key) as
select distinct cc.user_key
, first_value(z.campaign_id) over(partition by cc.user_key order by random() rows unbounded preceding) as campaign_id

from dbm.jobcase_email_content_cadence cc
inner join users u on u.user_key = cc.user_key
inner join
(
  select distinct a.zipcode2, e.campaign_id, e.campaign_rk, e.employer_name, e.send_priority
  from mart.zip_to_zip_within_50m_distances a
  inner join
  (
    select distinct job_zip, r.campaign_id, r.employer_name, i.send_priority, i.campaign_rk as campaign_rk
    from dbm.jc_jes_jobs_campaign_details_record r
    left join #id_rk i on i.campaign_id = r.campaign_id
    where r.campaign_id in (select campaign_id from #promo_ids)
  ) e on e.job_zip = a.zipcode
  WHERE (
    CASE WHEN campaign_id IN (SELECT campaign_id FROM #campaigns_too_small)
    THEN
      a.distance < 50
    ELSE
      a.distance < 30
    END
   )
) z on z.zipcode2 = substring(u.user_entered_zip_code,1,5)
left join dbm.jc_jes_jobs_email_send_record r on r.user_key = cc.user_key
  and r.send_date = convert_timezone('America/New_York', getdate())::date
left join (
          select s.user_key
          , s.employer_name
          , s.send_date
          , c.special_promotion
          , c.special_promotion_type
          from dbm.jc_jes_jobs_email_send_record s join dbm.jc_jes_jobs_campaign_details_record c on s.campaign_id = c.campaign_id and s.send_date = c.send_date
        ) r1 on r1.user_key = cc.user_key
            and r1.employer_name = z.employer_name
            and r1.send_date >= convert_timezone('America/New_York', getdate())::date - interval '3 days'
            and (r1.special_promotion = '1' and r1.special_promotion_type in ('BRANDING', 'VIRTUAL_HIRING_EVENT'))


where true
and cc.send_date = getdate()::date
and cc.sending_grouping = 'JOBCASE'
and cc.content_type in ('Company', 'JobAlert', 'Standard')

and
(
  (
    cc.cadence_email_domain_group in ('GMAIL', 'MSN')
    and cc.user_key IN
    (
      SELECT DISTINCT user_key
      FROM communications
      WHERE communication_channel = 'EMAIL'
      AND (communication_open_time_latest >= getdate() - INTERVAL '20 days'
      OR communication_click_time_latest >= getdate() - INTERVAL '20 days')
    )
    and cc.tplus_type not in ('tp-dslr-ne-', 'tp-dslrr-ne-')
  )
  or cc.cadence_email_domain_group not in ('GMAIL', 'MSN')
  or cc.cadence_email_domain_group is null
)
and cc.tplus_type != 'tp-wb-dslr-'

and cc.user_entered_email not in
(
  select distinct emailaddress
  from dbm.jobcase_preferences
  where offer_id in ('1', '15', '22', '26', '27', '36', '42', '43', '45', '60', '69', '72', '80','127', '132')
)
and r.user_key is null -- don't send jes jobs more than once to a member in a day
and r1.user_key is null -- don't send if user received branding or VHE send for same employer in last 3 days

;




-- commented out delete section, but it's here in case you need it...

-- delete from dbm.jc_jes_jobs_email_send_record
-- where pull_time >= date_add('minute',-10, convert_timezone('America/New_York', getdate()))
-- ;


insert into dbm.jc_jes_jobs_email_send_record
  select
  user_key
  , convert_timezone('America/New_York', getdate())::date as send_date
  , convert_timezone('America/New_York', getdate()) as pull_time
  , a.campaign_id
  , j.employer_name
  , j.campaign_version as campaign_version --test this

  from #audience a -- change to audience_cap with daily cap
  join #jobs j on j.campaign_id = a.campaign_id
  ;



--check counts by campaign_id and employer_name
select campaign_id, employer_name, count(distinct user_key), count(user_key) from dbm.jc_jes_jobs_email_send_record
where pull_time >= date_add('minute',-10, convert_timezone('America/New_York', getdate()))
group by 1,2
;



--check to see it's all there!
select * from dbm.jc_jes_jobs_campaign_details_record
where pull_time >= date_add('minute',-10, convert_timezone('America/New_York', getdate()))
;
