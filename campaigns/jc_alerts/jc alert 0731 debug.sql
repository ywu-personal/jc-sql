/***
Listgen: jc_alerts_test_rw

Dependencies
dbm.jobcase_email_content_cadence
dbm.jc_alerts_listgen_rw
dbm.jc_organic_legal_templates
dbm.keywords_to_remove
dbm.jc_alerts_search_recs_history
dbm.jc_email_company_suppression_patterns
dbm.jobcase_email_content_cadence

Dependent Scripts:
Output:
dbm.jc_alerts_listgen_rw (deletes and inserts)
dbm.hot_job_send_list

***/

/* PRE SQL */

-- Build today's list
DROP TABLE IF EXISTS #selected_jc_alert_audience;
CREATE TABLE #selected_jc_alert_audience
DISTKEY(user_key) AS (
SELECT
  user_key, cadence_email_domain_group
, MAX(registration_arrival_created_at) AS registration_arrival_created_at
-- MIN order : 'tp-dslc-','tp-dslc-jc-any-','tp-dslc-ph-any-','tp-dslo-','tp-dslr-','tp-dslrr-' (returns 1st one first)
, MIN(tplus_type) AS tplus_type
, MAX(pred_ctr) AS pred_ctr, MAX(pred_open_rate) AS pred_open_rate
FROM
  dbm.jobcase_email_content_cadence
WHERE
  send_date = CONVERT_TIMEZONE('America/New_York',SYSDATE)::DATE
  -- for now use cross-cadence from above
  AND (content_type IN ('JobAlert') OR (content_type IN ('JobSharing') AND tplus_type IN ('tp-dslc-','tp-dslo-')))
  -- cadence_email_domain_group has following values
  -- 'GMAIL', 'MSN', 'AOL', 'YAHOO', 'OTHER', '(null)'
  AND (
    (cadence_email_domain_group = 'GMAIL' AND pred_ctr > 0.01 AND pred_open_rate > 0.15 AND tplus_type NOT IN ('tp-dslr-ne-', 'tp-dslrr-ne-')) OR
    (cadence_email_domain_group = 'MSN' AND pred_ctr > 0.01) OR
    (cadence_email_domain_group IN ('AOL','YAHOO') AND pred_ctr > 0.008) OR
    (cadence_email_domain_group IN ('OTHER','(null)') AND pred_ctr > 0.005)
  )
GROUP BY 1,2
);

-- End of audience selection
-- ---------------------------------------------

DROP TABLE IF EXISTS #jc_alerts_listgen_rw;
CREATE TABLE #jc_alerts_listgen_rw (LIKE dbm.jc_alerts_listgen_rw);

INSERT INTO #jc_alerts_listgen_rw (
SELECT u.user_key,
CASE WHEN u.user_computed_email_domain_group IN ('GMAIL','YAHOO','MSN','AOL') THEN u.user_computed_email_domain_group
ELSE 'OTHER'
END email_address_domain_group,
u.user_computed_state,
u.user_computed_city,
u.user_entered_first_name,
u.user_entered_last_name,
u.user_entered_phone_1,
'post.jobcase.com' AS email_sending_domain,
'ET' AS email_service_provider,
NULL AS advertisement,
CASE WHEN dsl_a_alert<=45
THEN CASE WHEN SUBSTRING(MD5(u.user_key),1,1) < 8
THEN 'A'
ELSE 'B'
END
ELSE CASE WHEN DATEDIFF('day',membership_arrival_created_at,getdate()) < 10 AND DATEDIFF('day',membership_arrival_created_at,getdate()) >= 5
THEN CASE WHEN random() <= 0.75
THEN 'C'
ELSE CASE WHEN SUBSTRING(MD5(u.user_key),1,1) < 8
THEN 'A'
ELSE 'B'
END
END
ELSE CASE WHEN random() <= 0.33
THEN 'C'
ELSE CASE WHEN SUBSTRING(MD5(u.user_key),1,1) < 8
THEN 'A'
ELSE 'B'
END
END
END
END AB_category_bragi,
CASE WHEN u.user_computed_email_domain_group = 'YAHOO' OR SUBSTRING(MD5(u.user_key),9,1) < 4 THEN 'B' ELSE 'A' END AS AB_category_creative,
'A' AS job_search_impression_job_listing_key,
mul.zip_latitude AS job_search_impression_company_name,
mul.zip_longitude AS job_search_impression_city,
-- mul.zip as job_search_impression_state,
NULL AS job_search_impression_state,
NULL AS job_search_impression_job_title,
'@' || user_computed_city || '_Openings' AS from_name,
CASE WHEN EXTRACT(HOUR FROM CONVERT_TIMEZONE ('America/New_York',COALESCE(last_alert_arrival,last_jc_arrival,last_all_arrival,last_alert_open,last_all_open,membership_arrival_created_at,'2016-03-01 16:00:00'))) BETWEEN 9 AND 19
THEN EXTRACT(HOUR FROM CONVERT_TIMEZONE ('America/New_York',COALESCE(last_alert_arrival,last_jc_arrival,last_all_arrival,last_alert_open,last_all_open,membership_arrival_created_at,'2016-03-01 16:00:00')))
WHEN EXTRACT(HOUR FROM CONVERT_TIMEZONE ('America/New_York',COALESCE(last_alert_arrival,last_jc_arrival,last_all_arrival,last_alert_open,last_all_open,membership_arrival_created_at,'2016-03-01 16:00:00'))) BETWEEN 2 AND 8
THEN 7
ELSE 20 END wave
FROM
  users u
  -- restricted to JC Alerts audience
  NATURAL JOIN #selected_jc_alert_audience
  JOIN mart.jobcase_emailable_universe mu ON mu.user_key = u.user_key
  --
  LEFT JOIN
  (SELECT ar.user_key
  , MIN(date_diff('days',CASE WHEN ar.arrival_url ILIKE '%job%\\_alerts\\_%' OR ar.arrival_url ILIKE '%J%_Alerts%' OR ar.arrival_url ILIKE '%j%_offer=%'
  THEN ar.arrival_created_at
  ELSE '2010-01-01' END, getdate())) dsl_a_alert
  ,MAX(CASE WHEN arrival_url ILIKE '%job%\\_alerts\\_%' OR arrival_url ILIKE '%J%_Alerts%' OR arrival_url ILIKE '%j%_offer=%' THEN arrival_created_at END) last_alert_arrival
  ,MAX(CASE WHEN lower(arrival_domain) = 'jobcase.com' THEN arrival_created_at END) last_jc_arrival
  ,MAX(arrival_created_at) last_all_arrival
  FROM arrivals ar
  WHERE ar.arrival_created_at >= CONVERT_TIMEZONE ('America/New_York','UTC','2016-01-01')
  AND ar.arrival_computed_bot_classification IS NULL
  AND ar.arrival_computed_traffic_type = 'Email'
  GROUP BY 1) a ON a.user_key = u.user_key
  --
  LEFT JOIN (SELECT user_key, MIN(date_diff('days',COALESCE(er.arrival_created_at, '2010-01-01'),getdate())) dsl_r
  FROM event_registrations er GROUP BY 1) ereg ON ereg.user_key = u.user_key
  --
  LEFT JOIN (SELECT
  user_key
  ,MAX(CASE WHEN communication_vendor_template_name ILIKE 'J%_Alerts_Daily_%' THEN communication_open_time_latest END) last_alert_open
  ,MAX(communication_open_time_latest) last_all_open
  FROM communications
  WHERE communication_channel = 'EMAIL'
  AND communication_sent_time >= CONVERT_TIMEZONE ('America/New_York','UTC','2016-01-01')
  GROUP BY 1) e ON e.user_key = u.user_key
  --
  LEFT JOIN dbm.jc_mart_emailable_universe_locations mul ON mu.user_key = mul.user_key
);

ANALYZE #jc_alerts_listgen_rw;

/*
JC ALERTS - search rec test
*/

-- assign test groups
DROP TABLE IF EXISTS #jc_alerts_search_recs_test_group_splits;
CREATE TABLE #jc_alerts_search_recs_test_group_splits
DISTKEY(user_key) AS (
SELECT user_key
, 'A' AS test_group -- no active listgen tests
FROM #jc_alerts_listgen_rw
);

--- mapping to renormalize lowercased queries
DROP TABLE IF EXISTS #canonical_queries;
CREATE TABLE #canonical_queries AS
SELECT DISTINCT job_search_query,
job_search_query_lower
FROM (SELECT job_search_query,
job_search_query_lower,
ROW_NUMBER() OVER (PARTITION BY job_search_query_lower ORDER BY search_count DESC) item_rank
FROM (SELECT s.job_search_query job_search_query,
replace(replace(replace(replace(lower(regexp_replace(s.job_search_query,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '') job_search_query_lower,
COUNT(DISTINCT s.job_search_key) search_count
FROM mart.jobcase_emailable_universe l
NATURAL JOIN (SELECT user_key,
arrival_key,
job_search_query,
job_search_created_at,
job_search_key
FROM job_searches
WHERE arrival_created_at > date_add('month',-6,CONVERT_TIMEZONE('America/New_York', getdate()))
AND job_search_query IS NOT NULL
AND job_search_query != ''
AND LENGTH(job_search_query) BETWEEN 3 AND 255) s
GROUP BY 1,
2))
WHERE item_rank = 1 AND job_search_query_lower != '' AND job_search_query_lower !='keyword' AND job_search_query_lower IS NOT NULL AND job_search_query NOT IN (SELECT q_parameter FROM dbm.keywords_to_remove)
;

-- compile user job titles for which user has specified interest on their profiles (in the work preferences section)
DROP TABLE IF EXISTS #jc_alerts_profile_interests;
CREATE TABLE #jc_alerts_profile_interests
DISTKEY(user_key) AS (
SELECT user_key
, profile_user_entered_job_search_job_titles
FROM mart.jobcase_emailable_universe
NATURAL JOIN profiles
JOIN users USING(user_key)
WHERE user_key IN  (SELECT user_key FROM #jc_alerts_listgen_rw)
AND profile_user_entered_job_search_job_titles IS NOT NULL
);

-- current max number of elements in the JSON array for profile_user_entered_job_search_job_titles is 79. Let's limit it to 10 for now.
DROP TABLE IF EXISTS #jc_alerts_exploded_profile_interests;
CREATE TABLE #jc_alerts_exploded_profile_interests
DISTKEY(user_key) AS (
SELECT user_key, json_extract_array_element_text(profile_user_entered_job_search_job_titles,0) AS profile_interest_job_title FROM #jc_alerts_profile_interests WHERE profile_interest_job_title IS NOT NULL AND profile_interest_job_title <> '' UNION ALL
SELECT user_key, json_extract_array_element_text(profile_user_entered_job_search_job_titles,1) AS profile_interest_job_title FROM #jc_alerts_profile_interests WHERE profile_interest_job_title IS NOT NULL AND profile_interest_job_title <> '' UNION ALL
SELECT user_key, json_extract_array_element_text(profile_user_entered_job_search_job_titles,2) AS profile_interest_job_title FROM #jc_alerts_profile_interests WHERE profile_interest_job_title IS NOT NULL AND profile_interest_job_title <> '' UNION ALL
SELECT user_key, json_extract_array_element_text(profile_user_entered_job_search_job_titles,3) AS profile_interest_job_title FROM #jc_alerts_profile_interests WHERE profile_interest_job_title IS NOT NULL AND profile_interest_job_title <> '' UNION ALL
SELECT user_key, json_extract_array_element_text(profile_user_entered_job_search_job_titles,4) AS profile_interest_job_title FROM #jc_alerts_profile_interests WHERE profile_interest_job_title IS NOT NULL AND profile_interest_job_title <> '' UNION ALL
SELECT user_key, json_extract_array_element_text(profile_user_entered_job_search_job_titles,5) AS profile_interest_job_title FROM #jc_alerts_profile_interests WHERE profile_interest_job_title IS NOT NULL AND profile_interest_job_title <> '' UNION ALL
SELECT user_key, json_extract_array_element_text(profile_user_entered_job_search_job_titles,6) AS profile_interest_job_title FROM #jc_alerts_profile_interests WHERE profile_interest_job_title IS NOT NULL AND profile_interest_job_title <> '' UNION ALL
SELECT user_key, json_extract_array_element_text(profile_user_entered_job_search_job_titles,7) AS profile_interest_job_title FROM #jc_alerts_profile_interests WHERE profile_interest_job_title IS NOT NULL AND profile_interest_job_title <> '' UNION ALL
SELECT user_key, json_extract_array_element_text(profile_user_entered_job_search_job_titles,8) AS profile_interest_job_title FROM #jc_alerts_profile_interests WHERE profile_interest_job_title IS NOT NULL AND profile_interest_job_title <> '' UNION ALL
SELECT user_key, json_extract_array_element_text(profile_user_entered_job_search_job_titles,9) AS profile_interest_job_title FROM #jc_alerts_profile_interests WHERE profile_interest_job_title IS NOT NULL AND profile_interest_job_title <> ''
-- ... could go on, but I will stop here for testing purposes
);

DROP TABLE IF EXISTS #jc_alerts_cleaned_and_exploded_profile_interests;
CREATE TABLE #jc_alerts_cleaned_and_exploded_profile_interests
DISTKEY(user_key) AS (
SELECT user_key
, TRIM(profile_interest_job_title) AS profile_interest_job_title
, replace(replace(replace(replace(lower(regexp_replace(profile_interest_job_title,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '') profile_interest_job_title_lower
FROM #jc_alerts_exploded_profile_interests
WHERE LENGTH(TRIM(profile_interest_job_title)) > 2
AND NULLIF(TRIM(profile_interest_job_title),'') IS NOT NULL
AND profile_interest_job_title !='keyword'
-- 2019-05-08: suppress WFH keyword recommendations until we can support WFH job metadata and/or phrase matching in Bragi 3.0
AND profile_interest_job_title NOT ILIKE '%work%home%'
AND profile_interest_job_title NOT IN (SELECT q_parameter FROM dbm.keywords_to_remove)
);

-- compile user searches and attributes for ranking them
DROP TABLE IF EXISTS #jc_alerts_search_recs_available;
CREATE TABLE #jc_alerts_search_recs_available
DISTKEY(user_key) AS (
SELECT user_key
, user_computed_state
, job_search_query_lower
, searches
, clickouts
, searches_over_10
, most_recent_job_search_arrival
, explicit_searches
, implicit_searches
, datediff('days', most_recent_job_search_arrival, CONVERT_TIMEZONE('America/New_York', getdate())) AS dsljs
, min(datediff('days', most_recent_job_search_arrival, CONVERT_TIMEZONE('America/New_York', getdate()))) over(PARTITION BY user_key) AS dsljs_min
, max(datediff('days', most_recent_job_search_arrival, CONVERT_TIMEZONE('America/New_York', getdate()))) over(PARTITION BY user_key) AS dsljs_max
FROM
(
	SELECT l.user_key
	, user_computed_state
	, replace(replace(replace(replace(lower(regexp_replace(js.job_search_query,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '') job_search_query_lower
	, count(DISTINCT js.job_search_key) AS searches
	, count(DISTINCT CASE WHEN jsc.job_search_clickout_created_at IS NOT NULL THEN js.job_search_key END) AS clickouts
	, count(DISTINCT CASE WHEN js.job_search_jobs_estimate > 10 THEN js.job_search_key END) AS searches_over_10
	, max(js.arrival_created_at) AS most_recent_job_search_arrival
	, count(DISTINCT CASE WHEN js.job_search_reason IN ('USER_EXPLICIT') THEN js.job_search_key END) explicit_searches
	, count(DISTINCT CASE WHEN js.job_search_reason IN ('USER_IMPLICIT') THEN js.job_search_key END) implicit_searches
	FROM mart.jobcase_emailable_universe l
	JOIN users u USING(user_key)
	NATURAL JOIN
	(
		SELECT user_key
		, arrival_key
		FROM arrivals
		WHERE arrival_created_at > date_add('month',-6,CONVERT_TIMEZONE('America/New_York', getdate()))
		AND arrival_url NOT ILIKE '%JC_Job_Sharing%'
	) a
	NATURAL JOIN job_searches js
	LEFT JOIN job_search_clickouts jsc
		ON js.user_key = jsc.user_key
		AND js.job_search_key = jsc.job_search_key
	WHERE js.job_search_reason IN ('USER_EXPLICIT','USER_IMPLICIT')
	AND u.user_key IN (SELECT user_key FROM #jc_alerts_listgen_rw)
	GROUP BY 1,2,3
)
WHERE nullif(trim(job_search_query_lower),'') IS NOT NULL
	-- 2019-05-08: suppress WFH keyword recommendations until we can support WFH job metadata and/or phrase matching in Bragi 3.0
	AND job_search_query_lower NOT ILIKE '%work%home%'
);


-- rank the queries
DROP TABLE IF EXISTS #jc_alerts_search_recs_ranked;
CREATE TABLE #jc_alerts_search_recs_ranked
DISTKEY(user_key)
SORTKEY(rk) AS (
SELECT a.*
, coalesce(r.most_recent_send_date, '2018-09-01'::date) AS most_recent_send_date2
, clickouts::FLOAT / greatest(searches,.001) AS rk_field
, searches AS rk_field2
, row_number() over(PARTITION BY a.user_key ORDER BY coalesce(r.most_recent_send_date, '2018-09-01'::date) ASC, rk_field DESC, rk_field2 DESC) AS rk
, c.job_search_query
, coalesce(mul.zip, mul.city || ', ' || mul.state, mul.city, mul.state) AS user_location

FROM #jc_alerts_search_recs_available a
JOIN #jc_alerts_search_recs_test_group_splits t USING(user_key)
JOIN #canonical_queries c ON a.job_search_query_lower = c.job_search_query_lower
JOIN dbm.jc_mart_emailable_universe_locations mul ON mul.user_key = a.user_key
LEFT JOIN (
  SELECT user_key
  , replace(replace(replace(replace(lower(regexp_replace(job_search_query,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '') job_search_query_lower
  , max(send_date) AS most_recent_send_date
  FROM dbm.jc_alerts_search_recs_history
  WHERE send_date < CONVERT_TIMEZONE('America/New_York', getdate())::date
  GROUP BY 1,2
) r ON a.user_key = r.user_key AND a.job_search_query_lower = r.job_search_query_lower
WHERE searches_over_10 > 0
);

-- rank the profile interests
DROP TABLE IF EXISTS #jc_alerts_profile_interests_ranked;
CREATE TABLE #jc_alerts_profile_interests_ranked
DISTKEY(user_key)
SORTKEY(rk) AS (
SELECT a.*
, coalesce(r.most_recent_send_date, '2018-09-01'::date) AS most_recent_send_date2
, row_number() over(PARTITION BY a.user_key ORDER BY coalesce(r.most_recent_send_date, '2018-09-01'::date) ASC) AS rk
, coalesce(mul.zip, mul.city || ', ' || mul.state, mul.city, mul.state) AS user_location

FROM #jc_alerts_cleaned_and_exploded_profile_interests a
JOIN #jc_alerts_search_recs_test_group_splits t USING(user_key)
JOIN dbm.jc_mart_emailable_universe_locations mul ON mul.user_key = a.user_key
LEFT JOIN (
  SELECT user_key
  , replace(replace(replace(replace(lower(regexp_replace(job_search_query,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '') job_search_query_lower
  , max(send_date) AS most_recent_send_date
  FROM dbm.jc_alerts_search_recs_history
  WHERE send_date < CONVERT_TIMEZONE('America/New_York', getdate())::date
  GROUP BY 1,2
) r ON a.user_key = r.user_key AND a.profile_interest_job_title_lower = r.job_search_query_lower
WHERE most_recent_send_date2 <= CONVERT_TIMEZONE('America/New_York', getdate()) - interval '3 days'
);

-- Take the top query & locations based on different rankings of user searches
DROP TABLE IF EXISTS #jc_alerts_search_recs_history;
CREATE TABLE #jc_alerts_search_recs_history
DISTKEY(user_key) AS (
SELECT t.user_key
, CONVERT_TIMEZONE('America/New_York', getdate())::date AS send_date
, CASE
	WHEN p.profile_interest_job_title IS NOT NULL THEN 'A'
	ELSE 'C' END AS test_group
, CASE
	WHEN p.profile_interest_job_title IS NOT NULL THEN SUBSTRING(p.profile_interest_job_title, 1, 255) -- Override if profile interest exists
	ELSE SUBSTRING(r.job_search_query, 1, 255) END AS job_search_query -- else use our search reco
, SUBSTRING(r.user_location, 1, 100) AS job_search_location
FROM #jc_alerts_search_recs_test_group_splits t
LEFT JOIN #jc_alerts_search_recs_ranked r ON t.user_key = r.user_key AND r.rk = 1
LEFT JOIN #jc_alerts_profile_interests_ranked p ON p.user_key = t.user_key AND p.rk = 1
);


-- selector metrics (days since last job search) to determine if they should get reengage selector:
DROP TABLE IF EXISTS #jc_alerts_reengage_stats;
CREATE TABLE #jc_alerts_reengage_stats
DISTKEY(user_key) AS (
SELECT DISTINCT r.user_key
, datediff('days',coalesce(max(js.job_search_created_at),'2018-01-01'::date),getdate()) AS dsljs
FROM #jc_alerts_listgen_rw r
NATURAL JOIN
	(
		SELECT user_key
		, arrival_key
		FROM arrivals
		WHERE arrival_created_at > date_add('month',-6,CONVERT_TIMEZONE('America/New_York', getdate()))
		AND arrival_url NOT ILIKE '%JC_Job_Sharing%'
	) a
NATURAL JOIN job_searches js
GROUP BY 1
);

-- reengage selector users based on selector metrics
DROP TABLE IF EXISTS #jc_alerts_reengage_group;
CREATE TABLE #jc_alerts_reengage_group
DISTKEY(user_key) AS (
SELECT DISTINCT s.user_key
FROM #jc_alerts_reengage_stats s
WHERE s.dsljs > 12
AND SUBSTRING(MD5(CONCAT('wjc1', MD5(s.user_key))),1,1) < 'e'
);


-- remove sends for Hot Job emails
DROP TABLE IF EXISTS #mailable_audience;
CREATE TABLE #mailable_audience distkey(user_key) AS
select
cc.*
, datediff('day', a.latest_jc_arrival_created_at_local, convert_timezone('America/New_York', getdate())) as days_since_latest_jc_arrival
, datediff('day', u.membership_arrival_created_at::date, getdate()::date) as days_since_first_jcn_registration
, u.membership_arrival_application
, u.membership_arrival_created_at

from
dbm.jobcase_email_content_cadence cc
inner join users u on cc.user_key = u.user_key
left join
(
select
distinct user_key
, MAX(convert_timezone('America/New_York', arrival_created_at)) OVER (PARTITION BY user_entered_email) AS latest_jc_arrival_created_at_local
from arrivals
natural join users
where arrival_computed_bot_classification IS NULL
  and arrival_created_at > '2014-09-01'
  and membership_arrival_created_at is not null
  and arrival_application in ('jobcase.com','welcome.jobcase.com')
  and arrival_computed_traffic_source NOT IN ('Gunggo Pop Up','Facebook Preview','Not Traffic')
) a on a.user_key = cc.user_key

where true
and cc.send_date = convert_timezone('America/New_York', getdate())::date
and cc.sending_grouping = 'JOBCASE'
;


DROP TABLE IF EXISTS #welcome_hot_job_sends;
CREATE TABLE #welcome_hot_job_sends AS (
SELECT
  DISTINCT r.user_key
FROM
  dbm.v_jobcase_job_recommendations r
  INNER JOIN #mailable_audience a on a.user_key = r.user_key
  LEFT JOIN (
    SELECT DISTINCT user_key
    FROM
      event_registrations
			NATURAL JOIN arrivals
		WHERE
      lower(arrival_domain) IN ('careerboutique.com','everyjobforme.com','jobhat.com','jobsradar.com')
    ) rr ON rr.user_key = r.user_key
WHERE
  TRUE
  AND a.membership_arrival_application = 'welcome.jobcase.com'
  AND (a.days_since_latest_jc_arrival <= 90
  OR a.days_since_first_jcn_registration <= 30)
  AND rr.user_key IS NULL
);


DROP TABLE IF EXISTS #hot_job_send_list;
CREATE TABLE #hot_job_send_list
DISTKEY(user_key) AS (
SELECT
DISTINCT r.user_key
,CONVERT_TIMEZONE('America/New_York', getdate() + interval '1 day')::date AS send_date
FROM
#jc_alerts_listgen_rw r
INNER JOIN #mailable_audience a ON a.user_key = r.user_key
INNER JOIN dbm.v_jobcase_job_recommendations h ON h.user_key = r.user_key
LEFT JOIN #welcome_hot_job_sends wh ON wh.user_key = r.user_key
WHERE
MOD(DATEDIFF(DAY, a.membership_arrival_created_at::DATE, GETDATE()::DATE), 14) IN (1,3,5,7,9,11,13) -- mod14
AND wh.user_key IS NULL
AND (email_address_domain_group != 'MSN' or substring(md5(concat('s73j', md5(r.user_key))),5,1) < 'c')
);

DROP TABLE IF EXISTS #new_members;
CREATE TABLE #new_members
DISTKEY(user_key) AS (
SELECT DISTINCT a.user_key
, a.days_since_first_jcn_registration
FROM #mailable_audience a
WHERE a.days_since_first_jcn_registration <= 14
);

DROP TABLE IF EXISTS #jc_previous_jc_alerts_arrivals;
CREATE TABLE #jc_previous_jc_alerts_arrivals
DISTKEY(user_key) AS (
SELECT DISTINCT mu.user_key
, count(DISTINCT arrival_key) AS arrival_count
FROM public.arrivals a
NATURAL JOIN users u
JOIN mart.jobcase_emailable_universe mu ON u.user_key = mu.user_key
WHERE a.arrival_computed_traffic_type = 'Email'
  AND a.arrival_computed_bot_classification IS NULL
  AND a.arrival_created_at >= getdate() - interval '14 days'
  AND u.membership_arrival_created_at IS NOT NULL
  AND a.arrival_application = 'jobcase.com'
	AND a.arrival_url ILIKE '%jc_alerts%'
GROUP BY 1
);


DROP TABLE IF EXISTS #hot_job_send_list_exclude;
CREATE TABLE #hot_job_send_list_exclude AS (
SELECT
DISTINCT user_key
, send_date
FROM
#hot_job_send_list
WHERE
send_date = CONVERT_TIMEZONE('America/New_York', getdate()+ interval '1 day')::date
AND user_key NOT IN (SELECT DISTINCT user_key FROM #jc_previous_jc_alerts_arrivals
	WHERE arrival_count >=1
	)
AND user_key NOT IN (SELECT DISTINCT user_key FROM #new_members
  WHERE days_since_first_jcn_registration <= 7
	)
)
;

DELETE FROM #jc_alerts_search_recs_history
	WHERE
	user_key IN
		(SELECT DISTINCT user_key FROM #hot_job_send_list_exclude
		WHERE send_date = CONVERT_TIMEZONE('America/New_York', getdate()+interval '1 day')::date)
	AND send_date = CONVERT_TIMEZONE('America/New_York', getdate())::date
;

-- update tables statistics to improve join query performance below

-- FF Test --

-- set the control Friendly From = 'Jobcase'
UPDATE #jc_alerts_listgen_rw
SET
from_name = 'Jobcase'
;

DROP TABLE IF EXISTS #ff_coverage;
CREATE TABLE #ff_coverage AS (
SELECT outbound_job_search_query
, count(DISTINCT outbound_job_search_key) AS job_searches
, count(DISTINCT CASE WHEN search_yielded_matching_listing THEN outbound_job_search_key END) AS job_searches_yielded_matching_listing
, job_searches_yielded_matching_listing::float / job_searches AS coverage

FROM
(
SELECT outbound_job_search_query
, outbound_job_search_key
, CASE WHEN count(DISTINCT CASE WHEN outbound_job_search_impression_job_title ILIKE '%' || outbound_job_search_query || '%'
OR outbound_job_search_impression_company_name ILIKE '%' || outbound_job_search_query || '%'
THEN outbound_job_search_key END) = 0 THEN FALSE ELSE TRUE END AS search_yielded_matching_listing

FROM outbound_job_searches
NATURAL JOIN outbound_job_search_impressions ojsi

WHERE outbound_job_search_query IS NOT NULL
	AND outbound_job_search_created_at >= getdate() - interval '5 days'
GROUP BY 1,2
)
GROUP BY 1
ORDER BY 2 DESC
);

DROP TABLE IF EXISTS #users_with_ff;
CREATE TABLE #users_with_ff
DISTKEY(user_key) AS (
  SELECT
		r.user_key
		, h.job_search_query
	FROM #jc_alerts_listgen_rw r
	INNER JOIN #jc_alerts_search_recs_history h ON h.user_key = r.user_key AND h.send_date = CONVERT_TIMEZONE('America/New_York', getdate())::date
	INNER JOIN #ff_coverage ff ON ff.outbound_job_search_query = h.job_search_query
  LEFT JOIN dbm.jc_email_company_suppression_patterns p ON h.job_search_query ILIKE p.company_name_pattern
  	AND p.suppress_from_company_emails = TRUE
	WHERE TRUE
		AND p.company_name_pattern IS NULL
    AND ff.coverage >= .5
		AND length(h.job_search_query) < 30
		AND ff.job_searches > 200
);

-- FF expansion - testing 2019-05-21
-- show query as FF if at least one search for same job_search_query + job_search_location (zip)
-- have yielded a matching listing in the last 1 day
-- and fewer than 33chars, not suppressed company

-- using outbound job searches first
DROP TABLE IF EXISTS #job_search_query_and_locations_yielding_job_match;
CREATE TABLE #job_search_query_and_locations_yielding_job_match AS (
SELECT outbound_job_search_normalized_query
, outbound_job_search_location

FROM outbound_job_searches ojs
NATURAL JOIN outbound_job_search_impressions ojsi

WHERE outbound_job_search_normalized_query IS NOT NULL
	AND outbound_job_search_created_at >= getdate() - interval '1 days'
GROUP BY 1,2
HAVING count(DISTINCT CASE WHEN outbound_job_search_impression_job_title ILIKE '%' || outbound_job_search_normalized_query || '%'
OR outbound_job_search_impression_company_name ILIKE '%' || outbound_job_search_normalized_query || '%' THEN outbound_job_search_key END) > 0
);

-- supplementing with job searches
INSERT INTO #job_search_query_and_locations_yielding_job_match (
SELECT ojs.job_search_normalized_query AS outbound_job_search_normalized_query
, ojs.job_search_location AS outbound_job_search_location

FROM job_searches ojs
NATURAL JOIN job_search_impressions ojsi
LEFT JOIN #job_search_query_and_locations_yielding_job_match m
	ON m.outbound_job_search_normalized_query = ojs.job_search_query
	AND m.outbound_job_search_location = ojs.job_search_location

WHERE job_search_normalized_query IS NOT NULL
	AND job_search_created_at >= getdate() - interval '1 days'
	AND m.outbound_job_search_normalized_query IS NULL
GROUP BY 1,2
HAVING count(DISTINCT CASE WHEN job_search_impression_job_title ILIKE '%' || job_search_normalized_query || '%'
OR job_search_impression_company_name ILIKE '%' || job_search_normalized_query || '%' THEN job_search_key END) > 0
);

-- insert extra FF's available using the above
INSERT INTO #users_with_ff (
SELECT
	r.user_key
	, h.job_search_query
FROM #jc_alerts_listgen_rw r
INNER JOIN #jc_alerts_search_recs_history h ON h.user_key = r.user_key AND h.send_date = CONVERT_TIMEZONE('America/New_York', getdate())::date
INNER JOIN #job_search_query_and_locations_yielding_job_match ff
	ON ff.outbound_job_search_normalized_query = h.job_search_query
	AND ff.outbound_job_search_location = h.job_search_location
LEFT JOIN dbm.jc_email_company_suppression_patterns p ON h.job_search_query ILIKE p.company_name_pattern
	AND p.suppress_from_company_emails = TRUE
WHERE TRUE
	AND p.company_name_pattern IS NULL
	AND length(h.job_search_query) < 30
	AND r.user_key NOT IN (SELECT user_key FROM #users_with_ff)
);
-- done FF expansion


-- update the FF for users who meet the criteria defined above AND who fall into the test group --
UPDATE #jc_alerts_listgen_rw
SET
from_name = f.job_search_query || ' Jobs (via Jobcase)'
FROM #jc_alerts_listgen_rw r
INNER JOIN #users_with_ff f ON f.user_key = r.user_key
WHERE r.user_key IN (SELECT DISTINCT user_key FROM #users_with_ff)
;

-- Outbound Search Strategy Test 0709: copy this table for later use of the user_computed_city in FF
DROP TABLE IF EXISTS #jc_alerts_listgen_rw_copy;
CREATE TABLE #jc_alerts_listgen_rw_copy AS
    SELECT * FROM #jc_alerts_listgen_rw
;

-- track all users who could have a friendly from applied here. Not used in the html so this is OK.--
UPDATE #jc_alerts_listgen_rw
SET
user_computed_city = 'FF_Available'
FROM #jc_alerts_listgen_rw r
WHERE user_key IN (SELECT DISTINCT user_key FROM #users_with_ff)
;

CREATE TABLE #jc_alerts_ff_record
DISTKEY(user_key) AS (
SELECT
DISTINCT user_key
,CASE WHEN user_computed_city = 'FF_Available' THEN 'ff' ELSE 'none' END AS ff_group
,from_name
,CONVERT_TIMEZONE('America/New_York', getdate())::date AS send_date
FROM #jc_alerts_listgen_rw
);

DROP TABLE IF EXISTS #other_recommended_job_search_queries;
CREATE TABLE #other_recommended_job_search_queries
DISTKEY(user_key)
SORTKEY(other_recommended_job_search_query_rk) AS (
SELECT *
, sum(other_recommended_job_search_query_length) over(PARTITION BY user_key ORDER BY other_recommended_job_search_query_rk ROWS unbounded preceding) AS cum_length
FROM
  (
  SELECT r.user_key
  , r.job_search_query AS job_search_query
  , replace(s.job_search_query,'|','') AS other_recommended_job_search_query
  , most_recent_send_date2
  , rk_field
  , rk_field2
  , row_number() over(PARTITION BY r.user_key ORDER BY rk_field DESC, rk_field2 DESC) AS other_recommended_job_search_query_rk
  , length(other_recommended_job_search_query) AS other_recommended_job_search_query_length
  FROM #jc_alerts_search_recs_history r
  JOIN #jc_alerts_search_recs_ranked s
  	ON s.user_key = r.user_key

  WHERE r.send_date = CONVERT_TIMEZONE('America/New_York', getdate())::date
  	AND s.rk <> 1
  	AND s.job_search_query NOT ILIKE '%work%home%'
  	AND s.job_search_query NOT IN (SELECT q_parameter FROM dbm.keywords_to_remove)
  )
WHERE other_recommended_job_search_query_rk <= 5
);


-- remove keywords that when CONCATendated would be over 300 chars
-- because the field in JC Alerts Data Extension is currently max length 300
DELETE FROM #other_recommended_job_search_queries
WHERE cum_length >= 295
;


DROP TABLE IF EXISTS #other_recommended_job_search_queries_agg;
CREATE TABLE #other_recommended_job_search_queries_agg
DISTKEY(user_key) AS (
SELECT user_key
, listagg(other_recommended_job_search_query, '|') AS other_recommended_job_search_queries
FROM #other_recommended_job_search_queries
GROUP BY 1
);


DROP TABLE IF EXISTS #users_by_zip_population;
CREATE TABLE #users_by_zip_population AS
SELECT DISTINCT u.user_key
, u.user_entered_zip_code
, z.n_users
FROM users u
INNER JOIN
	(
	SELECT
	COUNT(DISTINCT user_key) AS n_users
	, user_entered_zip_code
	FROM users
	WHERE TRUE
	AND user_entered_zip_code IS NOT NULL
	GROUP BY 2
	) z ON u.user_entered_zip_code = z.user_entered_zip_code
WHERE TRUE
	AND u.user_entered_zip_code IS NOT NULL
	AND n_users <= 500
;


-- Test 07/09: Update test group from_name to '[City/State] Jobs (via Jobcase)'
UPDATE #jc_alerts_listgen_rw
SET
from_name = coalesce(cp.user_computed_city,cp.user_computed_state) || ' Jobs (via Jobcase)'
FROM #jc_alerts_listgen_rw r
INNER JOIN #jc_alerts_listgen_rw_copy cp on r.user_key = cp.user_key
INNER JOIN #jc_alerts_search_recs_history h on h.user_key = r.user_key
WHERE substring(md5(concat('itrbg0731', md5(r.user_key))),6,1) > '3'
     AND h.test_group != 'A'
     AND coalesce(cp.user_computed_city,cp.user_computed_state) is not null
;

-- --------------------------------------------------------
-- comment below lines during testing
-- populate persistent tables

DELETE dbm.jc_alerts_listgen_rw WHERE 1;
INSERT INTO dbm.jc_alerts_listgen_rw (SELECT * FROM #jc_alerts_listgen_rw);

DELETE FROM dbm.jc_alerts_search_recs_history WHERE send_date = CONVERT_TIMEZONE('America/New_York', getdate())::date;
INSERT INTO dbm.jc_alerts_search_recs_history (SELECT * FROM #jc_alerts_search_recs_history);

DELETE FROM dbm.hot_job_send_list;
INSERT INTO dbm.hot_job_send_list (SELECT * FROM #hot_job_send_list);

DELETE FROM dbm.jc_alerts_ff_record WHERE send_date = CONVERT_TIMEZONE('America/New_York', getdate())::date;
INSERT INTO dbm.jc_alerts_ff_record (SELECT * FROM #jc_alerts_ff_record);
