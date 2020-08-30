--
-- This script allocates users to JES hiring event campaigns (one per user) (cs.cs_events_promo) and populates following tables:
--   dbm.jc_jes_events_campaign_details_record
--   dbm.jc_jes_events_send_record
-- NOTE : 105k email limit per campaign excluding Lyft campaign

DELETE FROM dbm.jc_jes_events_campaign_details_record
WHERE pull_time >= date_add('minute',-40, convert_timezone('America/New_York', getdate()))
;

DELETE FROM dbm.jc_jes_events_send_record
WHERE pull_time >= date_add('minute',-40, convert_timezone('America/New_York', getdate()))
;


DROP TABLE IF EXISTS #campaign_ids_sent_b;
-- find sent campaign_ids from last 30 days excluding today
CREATE TABLE #campaign_ids_sent_b distkey(campaign_id) AS
SELECT DISTINCT
 	campaign_id
FROM dbm.jc_jes_events_send_record
WHERE send_date >= (getdate()::date - 30)
  -- pull_time is in EDT
  AND pull_time <= convert_timezone('America/New_York', getdate())::date + interval '0 hour'
  -- adjust if doing 2nd+ batch in a day
;


DROP TABLE IF EXISTS #campaign_ids_to_send;
CREATE TABLE #campaign_ids_to_send distkey(campaign_id) AS
SELECT DISTINCT campaign_id, employer_name
FROM
(
  (SELECT employer_name, event_date, campaign_id, job_title, job_city, job_state, left(REGEXP_REPLACE(event_zip, '[^0-9]', ''),5), left(REGEXP_REPLACE(job_zip, '[^0-9]', ''), 5)
  FROM cs.cs_events_promo
  WHERE
  event_date >= getdate()::date
  AND (event_date = (getdate()::date + cast(email_promo_offset AS int)))
  AND campaign_id NOT IN (SELECT campaign_id FROM #campaign_ids_sent_b)
  -- and campaign_id not in (select campaign_id from dbm.jc_jes_events_campaign_details_record) -- needed for the first 30 days of sends for non-amz events
  -- and campaign_id not in ('CAMPAIGN NOT PROMOTED') -- for non-amz events to not be promoted via email
  AND is_live = 1
  AND display_approval_status = 'APPROVED'
  AND is_no_promotion = 0
  AND email_promo_offset >= 0
  GROUP BY 1,2,3,4,5,6,7,8
  ORDER BY event_date ASC, campaign_id ASC
  )
)
;


-- calculate events sorted by event date & time (partition by campaign_id, unique_event_address)
DROP TABLE IF EXISTS #events_sorted_datetimes;
CREATE TABLE #events_sorted_datetimes distkey(unique_event_address_md5) AS
SELECT *
FROM
(
SELECT DISTINCT
coalesce(employer_alias, employer_name) as employer_name
, campaign_id
, event_address_1
, event_address_2
, event_city
, event_state
, left(REGEXP_REPLACE(event_zip, '[^0-9]', ''), 5) AS event_zip
, event_address_1 || event_address_2 || event_city || event_state || left(REGEXP_REPLACE(event_zip, '[^0-9]', ''), 5)
  AS unique_event_address
, first_value(special_promotion) over(PARTITION BY campaign_id, unique_event_address ORDER BY special_promotion DESC nulls LAST ROWS unbounded preceding) AS special_promotion
, first_value(event_url) over(PARTITION BY campaign_id, unique_event_address ORDER BY random() ROWS unbounded preceding) AS event_url
, trim(to_char(event_date, 'Month')) || ' ' || ltrim(to_char(event_date, 'DD'),'0') AS event_date_formatted
, trim(to_char(event_date, 'Month')) || ' ' || ltrim(to_char(event_date, 'DD'),'0') || ', ' || start_time || '-' || end_time AS event_datetime_formatted
, rank() over(PARTITION BY campaign_id, unique_event_address ORDER BY event_date_formatted) AS event_datetime_rk
, row_number() over(PARTITION BY campaign_id, unique_event_address ORDER BY event_date_formatted) AS event_date_time_row_number
, md5('4p5n' || md5(unique_event_address)) AS unique_event_address_md5
FROM cs.cs_events_promo e
WHERE campaign_id IN (SELECT campaign_id FROM #campaign_ids_to_send)
)
WHERE event_datetime_rk = event_date_time_row_number
;


-- collapse multiple event date & times into one row for each (campaign_id, unique_event_address_md5) pair
DROP TABLE IF EXISTS #events;
CREATE TABLE #events distkey(campaign_id) sortkey(event_rk) AS
SELECT DISTINCT
employer_name
, campaign_id
, event_address_1
, event_address_2
, event_city
, event_state
, left(REGEXP_REPLACE(event_zip, '[^0-9]', ''), 5) AS event_zip
, event_url
, special_promotion
, unique_event_address_md5
, nth_value(event_datetime_formatted, 1) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following)
|| coalesce('<br> ' || nth_value(event_datetime_formatted, 2) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_datetime_formatted, 3) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_datetime_formatted, 4) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_datetime_formatted, 5) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_datetime_formatted, 6) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_datetime_formatted, 7) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_datetime_formatted, 8) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_datetime_formatted, 9) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_datetime_formatted, 10) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
AS event_datetimes_formatted
, nth_value(event_date_formatted, 1) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following)
|| coalesce('<br> ' || nth_value(event_date_formatted, 2) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_date_formatted, 3) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_date_formatted, 4) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_date_formatted, 5) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_date_formatted, 6) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_date_formatted, 7) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_date_formatted, 8) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_date_formatted, 9) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
|| coalesce('<br> ' || nth_value(event_date_formatted, 10) over(PARTITION BY campaign_id, unique_event_address_md5 ORDER BY event_datetime_rk ROWS BETWEEN unbounded preceding AND unbounded following), '')
AS event_dates_formatted
, dense_rank() over(PARTITION BY campaign_id ORDER BY unique_event_address_md5) AS event_rk
FROM #events_sorted_datetimes
;

--print list of events
SELECT * FROM #events;




-- log event details (as displayed in email : max 5 limit)
INSERT INTO dbm.jc_jes_events_campaign_details_record
SELECT DISTINCT
e.campaign_id
, convert_timezone('America/New_York', getdate())::date AS send_date
, convert_timezone('America/New_York', getdate()) AS pull_time
, e.employer_name::varchar(255)
, first_value(coalesce(p.promoted_job_title, p.job_title)) over(PARTITION BY campaign_id ORDER BY coalesce(promoted_job_title,job_title) ROWS unbounded preceding)::varchar(255) AS job_title
, first_value(p.job_city) over(PARTITION BY campaign_id ORDER BY coalesce(promoted_job_title,job_title) ROWS unbounded preceding)::varchar(255) AS job_city
, first_value(p.job_state) over(PARTITION BY campaign_id ORDER BY coalesce(promoted_job_title,job_title) ROWS unbounded preceding)::varchar(100) AS job_state
, first_value(left(REGEXP_REPLACE(p.job_zip, '[^0-9]', ''), 5)) over(PARTITION BY campaign_id ORDER BY coalesce(promoted_job_title,job_title) ROWS unbounded preceding)::varchar(100) AS job_zip
, e.event_address_1::varchar(255)
, e.event_address_2::varchar(255)
, e.event_city::varchar(255)
, e.event_state::varchar(100)
, left(REGEXP_REPLACE(e.event_zip, '[^0-9]', ''), 5)::varchar(100)
, e.event_url::varchar(1000)
, e.event_datetimes_formatted::varchar(4000)
, e.event_rk
, e.special_promotion::varchar(255)
, e.event_dates_formatted::varchar(4000)
, p.application_event

FROM cs.cs_events_promo p
JOIN #events e USING(campaign_id)
WHERE campaign_id IN (SELECT campaign_id FROM #campaign_ids_to_send)
  AND e.event_rk <= 5 -- limit to max 5 event blocks per email
;


-- assign user to one event campaign based on following eligibility criterias -
--  * within 30 miles
--  * in jc_mailable_universe_matrix_classification and email opened or clicked in last 20 days
--  * user not opted out of specific offers (dbm.jobcase_preferences)
--  * and no other JES event email send today
DROP TABLE IF EXISTS #audience;
CREATE TABLE #audience distkey(user_key) AS
SELECT DISTINCT user_key
, campaign_id
, sent_last_3_days
FROM
(
SELECT DISTINCT cc.user_key
, first_value(z.campaign_id) over(PARTITION BY cc.user_key ORDER BY random() ROWS unbounded preceding) AS campaign_id
, row_number() over(partition by z.campaign_id order by random()) as user_rk
, p.max_names
, case when r1.user_key is not null then 'sent' else 'not_sent' end as sent_last_3_days

FROM dbm.jobcase_email_content_cadence cc
inner join users u on u.user_key = cc.user_key
INNER JOIN
(
  SELECT DISTINCT a.zipcode2, e.campaign_id, e.employer_name
  FROM mart.zip_to_zip_within_50m_distances a
  INNER JOIN
  (
    SELECT DISTINCT (CASE WHEN event_zip = '' THEN job_zip ELSE event_zip END) AS event_zip, campaign_id, employer_name
    FROM dbm.jc_jes_events_campaign_details_record
    WHERE campaign_id IN (SELECT campaign_id FROM #campaign_ids_to_send)
  ) e ON e.event_zip = a.zipcode
 WHERE (
      a.distance < 30
   )
) z ON z.zipcode2 = substring(u.user_entered_zip_code,1,5)
join cs.cs_events_promo p on z.campaign_id = p.campaign_id
left join dbm.jc_jes_events_send_record r on r.user_key = cc.user_key
  and r.send_date = getdate()::date
left join dbm.jc_jes_events_send_record r1 on r1.user_key = cc.user_key
  and r1.employer_name = z.employer_name
  and r1.send_date >= convert_timezone('America/New_York', getdate())::date - interval '3 days'
left join dbm.jc_jes_events_send_record r2 on r2.user_key = cc.user_key
  and r2.employer_name = z.employer_name
  and r2.send_date >= convert_timezone('America/New_York', getdate())::date - interval '1 day'

WHERE TRUE
and cc.send_date = getdate()::date
and cc.sending_grouping = 'JOBCASE'
and cc.content_type in ('Company', 'JobAlert', 'Standard')

and
(
  (
    cc.cadence_email_domain_group in ('GMAIL','MSN')
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

AND cc.user_entered_email NOT IN
(
  SELECT DISTINCT emailaddress
  FROM dbm.jobcase_preferences
  WHERE offer_id IN ('1', '15', '22', '26', '27', '36', '42', '43', '45', '60', '69', '72', '80','127', '132')
)
and r.user_key is null
and r2.user_key is null
and cc.user_key not in (
  select r.user_key
  from dbm.jc_jes_events_send_record r
  inner join dbm.jc_jes_events_campaign_details_record cd on r.campaign_id = cd.campaign_id
  and cd.send_date = getdate()::date
  and r.send_date < getdate()::date
)
)
where user_rk <= max_names
;


SELECT count(*) FROM #audience;

DROP TABLE IF EXISTS #campaigns_too_small;
CREATE TEMP TABLE #campaigns_too_small AS
SELECT
campaign_id
,count(DISTINCT user_key) user_count
FROM
#audience
GROUP BY 1
HAVING user_count <10000
-- union
-- (select campaign_id, count(distinct user_key) user_count from #audience
-- where campaign_id in (select campaign_id from #campaign_ids_to_send where employer_name='Lyft')
-- group by 1) --include lyft in "too small" so the radius is expanded to 50 mi

;

SELECT * FROM #campaigns_too_small;

-- If the audience is too small for the campaign, increase distance filter to 50 miles
DROP TABLE IF EXISTS #audience;
CREATE TABLE #audience distkey(user_key) AS
SELECT DISTINCT user_key
, campaign_id
, sent_last_3_days
FROM
(
SELECT DISTINCT cc.user_key
, first_value(z.campaign_id) over(PARTITION BY cc.user_key ORDER BY random() ROWS unbounded preceding) AS campaign_id
, row_number() over(partition by z.campaign_id order by random()) as user_rk
, p.max_names
, case when r1.user_key is not null then 'sent' else 'not_sent' end as sent_last_3_days

FROM dbm.jobcase_email_content_cadence cc
inner join users u on u.user_key = cc.user_key
INNER JOIN
-- all zips within X miles of a job being hired for at a campaign_id's event
-- intersect with mailable members in those zips
(
  SELECT DISTINCT a.zipcode2, e.campaign_id, e.employer_name
  FROM mart.zip_to_zip_within_50m_distances a
  INNER JOIN
  (
    SELECT DISTINCT (CASE WHEN event_zip = '' THEN job_zip ELSE event_zip END) AS event_zip, campaign_id, employer_name
    FROM dbm.jc_jes_events_campaign_details_record
    WHERE campaign_id IN (SELECT campaign_id FROM #campaign_ids_to_send)
  ) e ON e.event_zip = a.zipcode
 WHERE (
    CASE WHEN campaign_id IN (SELECT campaign_id FROM #campaigns_too_small)
    THEN
      a.distance < 50
    ELSE
      a.distance < 30
    END
   )
) z ON z.zipcode2 = substring(u.user_entered_zip_code,1,5)
join cs.cs_events_promo p on z.campaign_id = p.campaign_id
left join dbm.jc_jes_events_send_record r on r.user_key = cc.user_key
  and r.send_date = getdate()::date
left join dbm.jc_jes_events_send_record r1 on r1.user_key = cc.user_key
  and r1.employer_name = z.employer_name
  and r1.send_date >= convert_timezone('America/New_York', getdate())::date - interval '3 days'
left join dbm.jc_jes_events_send_record r2 on r2.user_key = cc.user_key
  and r2.employer_name = z.employer_name
  and r2.send_date >= convert_timezone('America/New_York', getdate())::date - interval '1 day'

WHERE TRUE
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

AND cc.user_entered_email NOT IN
(
  SELECT DISTINCT emailaddress
  FROM dbm.jobcase_preferences
  WHERE offer_id IN ('1', '15', '22', '26', '27', '36', '42', '43', '45', '60', '69', '72', '80','127', '132')
)
AND r.user_key IS NULL
and r1.user_key is null
and r2.user_key is null
and cc.user_key not in (
  select r.user_key
  from dbm.jc_jes_events_send_record r
  inner join dbm.jc_jes_events_campaign_details_record cd on r.campaign_id = cd.campaign_id
  and cd.send_date = getdate()::date
  and r.send_date < getdate()::date
)
)
where user_rk <= max_names
;


/* Limits campaigns to 80 k sends */
DROP TABLE IF EXISTS #audience_test;
CREATE TABLE #audience_test distkey(user_key) AS
SELECT
  *
FROM (
  SELECT
    ROW_NUMBER() OVER (PARTITION BY campaign_id ORDER BY random()) AS r,
    t.*
  FROM
    #audience t
    WHERE t.campaign_id NOT IN (SELECT campaign_id FROM #campaign_ids_to_send WHERE employer_name = 'Lyft') --exclude Lyft campaigns from cap
) x
WHERE
  x.r <= 80000
UNION

SELECT * FROM (
  SELECT
    ROW_NUMBER() OVER (PARTITION BY campaign_id ORDER BY random()) AS r,
    t.*
  FROM
    #audience t
    WHERE t.campaign_id IN (SELECT campaign_id FROM #campaign_ids_to_send WHERE employer_name = 'Lyft') --exclude Lyft campaigns from cap
) x
WHERE
  x.r <= 80000
;

SELECT campaign_id, count(*), count(DISTINCT user_key)
FROM #audience_test
GROUP BY 1
ORDER BY 1
;

-- holdout 1/4 of users from being able to receive event sends from same employer 2 days apart
-- keep that 1/4 only aable to receive event sends from same employer 4 days apart
-- implemented july 7 2020
insert into dbm.jc_jes_events_holdout_group
select distinct user_key
, convert_timezone('America/New_York', getdate())::date AS holdout_date
from #audience_test
where true
and sent_last_3_days = 'sent'
and substring(md5(concat('holdout_07072020', md5(user_key))), 3, 1) < '4'
;

delete from #audience_test where user_key in
  (
    select distinct user_key
    from dbm.jc_jes_events_holdout_group
    where holdout_date = convert_timezone('America/New_York', getdate())::date
  )
;



INSERT INTO dbm.jc_jes_events_send_record
(SELECT DISTINCT a.user_key
, convert_timezone('America/New_York', getdate())::date AS send_date
, convert_timezone('America/New_York', getdate()) AS pull_time
, a.campaign_id
, e.employer_name
, '1' AS campaign_version -- flags this as non-correction
FROM #audience_test a
JOIN #events e ON e.campaign_id = a.campaign_id)
;



/************************
-- Check volumes updated
************************/
-- send record
SELECT pull_time, campaign_id, count(*), count(DISTINCT user_key)
FROM dbm.jc_jes_events_send_record
WHERE pull_time >= getdate() - interval '1 day'
GROUP BY 1,2
ORDER BY 1
LIMIT 1000
;

-- campaign_details record
SELECT pull_time, campaign_id, count(*), count(DISTINCT campaign_id)
FROM dbm.jc_jes_events_campaign_details_record
WHERE pull_time >= getdate() - interval '1 day'
GROUP BY 1,2
ORDER BY 1
LIMIT 1000
;

/************************
-- Add left out military
************************/

DROP TABLE IF EXISTS #military;
CREATE TABLE #military AS

(
SELECT profile_key,
user_key
FROM profiles
JOIN dbm.jobcase_email_content_cadence cc USING(profile_key)
WHERE profile_user_entered_military_affiliation IN ('VETERAN','YES','ACTIVE_DUTY','RESERVE','RETIRED','NATIONAL_GUARD', 'SPOUSE', 'DEPENDENT')
and cc.send_date = getdate()::date
and cc.sending_grouping = 'JOBCASE'
and cc.content_type in ('Company', 'JobAlert', 'Standard')
-- limit 100
UNION
SELECT profile_key,
user_key
FROM profiles
JOIN dbm.jobcase_email_content_cadence cc USING(profile_key)
WHERE profile_user_entered_jobs_company_name ILIKE '%Army%' OR profile_user_entered_jobs_company_name ILIKE '%Navy%' OR lower(profile_user_entered_jobs_company_name) SIMILAR TO '%(united states|u.s.) (army|navy|air force|coast guard|marines)%' OR lower(profile_user_entered_jobs_company_name) SIMILAR TO '%(army|navy|air force|coast guard|marines|national guard|military)%'
and cc.send_date = getdate()::date
and cc.sending_grouping = 'JOBCASE'
and cc.content_type in ('Company', 'JobAlert', 'Standard')
)
;

DROP TABLE IF EXISTS #campaigns_zips;
CREATE TABLE #campaigns_zips AS
  SELECT campaign_id,
  CASE WHEN event_zip='' THEN job_zip ELSE event_zip END AS zip
  FROM dbm.jc_jes_events_campaign_details_record WHERE send_date = getdate()::date AND employer_name = 'Wells Fargo';

SELECT * FROM #campaigns_zips;

SELECT count(*) FROM #audience;

DROP TABLE IF EXISTS #geo_military;
CREATE TABLE #geo_military AS
SELECT s.user_key, campaign_id
FROM #military m INNER JOIN #audience s ON m.user_key = s.user_key
WHERE campaign_id IN (SELECT campaign_id FROM #campaigns_zips);

SELECT count(*) FROM #geo_military;

INSERT INTO dbm.jc_jes_events_send_record
SELECT
v.user_key
, convert_timezone('America/New_York', getdate())::date AS send_date
, convert_timezone('America/New_York', getdate()) AS pull_time
, v.campaign_id
, 'Wells Fargo' AS employer_name
, '1' AS campaign_version

FROM #geo_military v
LEFT JOIN (SELECT * FROM dbm.jc_jes_events_send_record WHERE send_date = getdate()::date AND employer_name = 'Wells Fargo') r ON v.user_key = r.user_key
WHERE r.user_key IS NULL;

/************************
-- Check volumes updated again
************************/
-- send record
SELECT pull_time, campaign_id, count(*), count(DISTINCT user_key)
FROM dbm.jc_jes_events_send_record
WHERE pull_time >= getdate() - interval '1 day'
GROUP BY 1,2
ORDER BY 1
LIMIT 1000
;

-- campaign_details record
SELECT pull_time, campaign_id, count(*), count(DISTINCT campaign_id)
FROM dbm.jc_jes_events_campaign_details_record
WHERE pull_time >= getdate() - interval '1 day'
GROUP BY 1,2
ORDER BY 1
LIMIT 1000
;
