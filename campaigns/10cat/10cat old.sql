/***
Listgen: JC_ALL_Jobs_10CAT_LOGO
Dependent Scripts:
***/
/* PRE SQL */
--start here

DELETE FROM dbm.jc_job_searches_keyword_recommendation_record where send_date = convert_timezone('America/New_York',getdate())::DATE;

-- Pull in today's list using cadence set in separate scoring_10cat.sql script
DROP TABLE if exists #jc_jobs_list_today;
CREATE TABLE #jc_jobs_list_today distkey(user_key) AS
SELECT DISTINCT mu.user_key
, mu.email_domain_group as user_computed_email_domain_group
FROM mart.jobcase_emailable_universe mu
join dbm.jc_10cat_cadences_record r using(user_key)
where r.send_date = convert_timezone('America/New_York', getdate())::date
;
/* This generates job search recommendations for 10CAT logo
The listgen preSQL is set up to pull recommendations from here for users who recieve job searches ONLY
In testing this was a win for these users; flat or loss for users who received specific job listings in email
https://percipio.jira.com/wiki/spaces/JMS/pages/313000021/10CATLogo+-+Generate+more+personalized+Top+Searches+recommendations
*/



-- cbsa to zip mapping
drop table if exists #cbsas;
create table #cbsas as
select distinct cbsa_title, cbsa_code, cbsa_population, count(distinct user_key) as cbsa_mailable_members
from analytics.zip_cbsa c
join dbm.jc_mart_emailable_universe_locations mul on c.zipcode = mul.zip
group by 1,2,3
;

drop table if exists #cbsas_to_zip;
create table #cbsas_to_zip as
select z.*, c.cbsa_mailable_members
from analytics.zip_cbsa z
natural join #cbsas c
;

-- Clickouts Jaccard
DROP TABLE IF EXISTS #sendable_universe_clickouts;
CREATE TABLE #sendable_universe_clickouts distkey(user_key) AS
SELECT a.user_key
, user_computed_state
, cz.cbsa_code
, cz.cbsa_title
, cz.cbsa_mailable_members
, job_search_query_lower
, ROW_NUMBER() OVER (PARTITION BY user_key ORDER BY job_search_clickout_created_at DESC) kw_rank
FROM
(
SELECT l.user_key
, mul.state as user_computed_state
, mul.zip
, c.job_search_clickout_created_at
, replace(replace(replace(replace(lower(regexp_replace(job_search_query,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '') job_search_query_lower
, ROW_NUMBER() OVER (PARTITION BY l.user_key, job_search_query_lower ORDER BY job_search_clickout_created_at DESC) rec
FROM mart.jobcase_emailable_universe l

NATURAL JOIN
(
SELECT user_key
, arrival_key
FROM arrivals
WHERE arrival_created_at > date_add('month',-6,getdate())
and arrival_url not ilike '%JC_Job_Sharing_Hot_Job%'
) a

NATURAL JOIN job_searches js

NATURAL JOIN
(
SELECT user_key
, arrival_key
, job_search_impression_key
, job_search_clickout_created_at
FROM job_search_clickouts c
WHERE job_search_clickout_disposition = 'SUCCESS'
AND job_search_clickout_status = 'POSTED'
AND arrival_created_at > date_add('month',-6,getdate())
) c

JOIN dbm.jc_mart_emailable_universe_locations mul on l.user_key = mul.user_key
) a
LEFT JOIN #cbsas_to_zip cz on a.zip = cz.zipcode
WHERE a.rec = 1
and a.job_search_query_lower is not null;

------------- STATE Versions

------------- This table segments by state and job search query; compiles count of how many users clicked out on that query, in that state
DROP TABLE IF EXISTS #click_counts;
CREATE TABLE #click_counts AS
select user_computed_state
, job_search_query_lower
, count(distinct user_key) users_clicked
FROM #sendable_universe_clickouts
NATURAL JOIN users u
WHERE job_search_query_lower IS NOT NULL
AND job_search_query_lower <> ''
GROUP BY 1,2;

------------- This table segments by state; ranks the job search queries by state from most to least users clicked
DROP TABLE IF EXISTS #ranked_click_counts;
CREATE TABLE #ranked_click_counts AS
SELECT user_computed_state
, job_search_query_lower
, users_clicked
, ROW_NUMBER() OVER(PARTITION BY user_computed_state ORDER BY users_clicked DESC) rk
FROM #click_counts;

------------- this table compares two queries, segmented at the state level. Calculates the jaccard distance (eg. overlap in users clicked) beween total users clicked on both 1 and 2
DROP TABLE IF EXISTS #click_jaccard;
CREATE TABLE #click_jaccard AS
SELECT query1
, query2
, user_computed_state
, users_clicked_1 click_volume
, 100*count(distinct user_key)::FLOAT/AVG(total_clicks) overlap
FROM (
SELECT c1.user_key
, c1.user_computed_state
, c1.job_search_query_lower query1
, c2.job_search_query_lower query2
, cc1.users_clicked users_clicked_1
, cc2.users_clicked users_clicked_2
, cc1.users_clicked + cc2.users_clicked total_clicks
FROM #sendable_universe_clickouts c1
INNER JOIN #sendable_universe_clickouts c2 ON c1.user_key = c2.user_key AND c1.job_search_query_lower <> c2.job_search_query_lower
INNER JOIN #click_counts cc1 ON cc1.job_search_query_lower = c1.job_search_query_lower AND cc1.user_computed_state = c1.user_computed_state
INNER JOIN #ranked_click_counts cc2 ON cc2.job_search_query_lower = c2.job_search_query_lower AND cc2.user_computed_state = c2.user_computed_state
WHERE c1.job_search_query_lower IS NOT NULL
AND c2.job_search_query_lower IS NOT NULL
AND cc2.rk <= 1000)
GROUP BY 1,2,3,4;
----------- Deletes from this table where there is less than 10% overlap (eg. less than 10% of users who clicked out on 1 also clicked out on 2)
DELETE FROM #click_jaccard
WHERE overlap < 10;

------------- CBSA Versions

------------- This table segments by state and job search query; compiles count of how many users clicked out on that query, in that cbsa
DROP TABLE IF EXISTS #click_counts_cbsa;
CREATE TABLE #click_counts_cbsa DISTSTYLE ALL AS
select job_search_query_lower, cbsa_code, count(distinct user_key) users_clicked
FROM #sendable_universe_clickouts
NATURAL JOIN users u
WHERE job_search_query_lower IS NOT NULL
AND job_search_query_lower <> ''
and cbsa_code is not null
and cbsa_mailable_members >= 1000
GROUP BY 1,2;

------------- This table segments by state; ranks the job search queries by cbsa from most to least users clicked
DROP TABLE IF EXISTS #ranked_click_counts_cbsa;
CREATE TABLE #ranked_click_counts_cbsa DISTSTYLE ALL AS
SELECT cbsa_code
, job_search_query_lower
, users_clicked
, ROW_NUMBER() OVER(PARTITION BY cbsa_code ORDER BY users_clicked DESC) rk
FROM #click_counts_cbsa;

------------- this table compares two queries, segmented at the state level. Calculates the jaccard distance (eg. overlap in users clicked) beween total users clicked on both 1 and 2
DROP TABLE IF EXISTS #click_jaccard_cbsa;
CREATE TABLE #click_jaccard_cbsa AS
SELECT query1
, query2
, cbsa_code
, users_clicked_1 click_volume
, 100*count(distinct user_key)::FLOAT/AVG(total_clicks) overlap
FROM (
SELECT c1.user_key
, c1.cbsa_code
, c1.job_search_query_lower query1
, c2.job_search_query_lower query2
, cc1.users_clicked users_clicked_1
, cc2.users_clicked users_clicked_2
, cc1.users_clicked + cc2.users_clicked total_clicks
FROM #sendable_universe_clickouts c1
INNER JOIN #sendable_universe_clickouts c2 ON c1.user_key = c2.user_key AND c1.job_search_query_lower <> c2.job_search_query_lower
INNER JOIN #click_counts_cbsa cc1 ON cc1.job_search_query_lower = c1.job_search_query_lower AND cc1.cbsa_code = c1.cbsa_code
INNER JOIN #ranked_click_counts_cbsa cc2 ON cc2.job_search_query_lower = c2.job_search_query_lower AND cc2.cbsa_code = c2.cbsa_code
WHERE c1.job_search_query_lower IS NOT NULL
AND c2.job_search_query_lower IS NOT NULL
AND cc2.rk <= 200)
GROUP BY 1,2,3,4;

----------- Deletes from this table where there is less than 10% overlap (eg. less than 10% of users who clicked out on 1 also clicked out on 2)
DELETE FROM #click_jaccard_cbsa
WHERE overlap < 10 or click_volume < 5;

------------- This table segments by state and job search query; ranks possible suggestions for a user based on the overlap between suggested queries and the clickout query
DROP TABLE IF EXISTS #clickout_recs;
CREATE TABLE #clickout_recs distkey(user_key) AS
SELECT user_key
, s.user_computed_state
, s.job_search_query_lower
, query2
, ROW_NUMBER() OVER(PARTITION BY user_key ORDER BY overlap DESC) as item_rank
FROM #sendable_universe_clickouts s
INNER JOIN #click_jaccard cj ON cj.user_computed_state = s.user_computed_state AND cj.query1 = s.job_search_query_lower
;

------------- This table segments by state and job search query; ranks possible suggestions for a user based on the overlap between suggested queries and the clickout query
DROP TABLE IF EXISTS #clickout_recs_cbsa;
CREATE TABLE #clickout_recs_cbsa distkey(user_key) AS
SELECT user_key
, s.cbsa_code
, s.job_search_query_lower
, query2
, ROW_NUMBER() OVER(PARTITION BY user_key ORDER BY overlap DESC) as item_rank
FROM #sendable_universe_clickouts s
INNER JOIN #click_jaccard_cbsa cj ON cj.cbsa_code = s.cbsa_code AND cj.query1 = s.job_search_query_lower
WHERE s.cbsa_code is not null
;

------- SEARCH Jaccard RECOMMENDATIONS: same process is run through for searches for users, except now searches are compared against searches
DROP TABLE IF EXISTS #sendable_universe_searches;
CREATE TABLE #sendable_universe_searches distkey(user_key) AS
SELECT a.user_key
, user_computed_state
, cz.cbsa_code
, cz.cbsa_title
, cz.cbsa_mailable_members
, job_search_query_lower
, ROW_NUMBER() OVER (PARTITION BY user_key ORDER BY job_search_created_at DESC) kw_rank
FROM
(
SELECT l.user_key
, mul.state as user_computed_state
, mul.zip
, js.job_search_created_at
, replace(replace(replace(replace(lower(regexp_replace(job_search_query,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '') job_search_query_lower
, ROW_NUMBER() OVER (PARTITION BY l.user_key, job_search_query_lower ORDER BY job_search_created_at DESC) rec
FROM mart.jobcase_emailable_universe l
NATURAL JOIN
(
SELECT user_key,
arrival_key
FROM arrivals
WHERE arrival_created_at > date_add('month',-6,getdate())
and arrival_url not ilike '%JC_Job_Sharing_Hot_Job%'
) a
NATURAL JOIN job_searches js
JOIN users u using(user_key)
JOIN dbm.jc_mart_emailable_universe_locations mul on l.user_key = mul.user_key

) a
LEFT JOIN #cbsas_to_zip cz on a.zip = cz.zipcode
WHERE a.rec = 1
;

DROP TABLE IF EXISTS #search_counts;
CREATE TABLE #search_counts AS
select user_computed_state
, job_search_query_lower
, count(distinct user_key) users_searched
FROM #sendable_universe_searches
NATURAL JOIN users u
WHERE job_search_query_lower IS NOT NULL
AND job_search_query_lower <> ''
GROUP BY 1,2;

DROP TABLE IF EXISTS #ranked_search_counts;
CREATE TABLE #ranked_search_counts AS
SELECT user_computed_state
, job_search_query_lower
, users_searched
, ROW_NUMBER() OVER(PARTITION BY user_computed_state ORDER BY users_searched DESC) rk
FROM #search_counts;

DROP TABLE IF EXISTS #search_jaccard;
CREATE TABLE #search_jaccard AS
SELECT query1
, query2
, user_computed_state
, users_searched_1 search_volume
, 100*count(distinct user_key)::FLOAT/AVG(total_searches) overlap
FROM (
SELECT c1.user_key
, c1.user_computed_state
, c1.job_search_query_lower query1
, c2.job_search_query_lower query2
, cc1.users_searched users_searched_1
, cc2.users_searched users_searched_2
, cc1.users_searched + cc2.users_searched total_searches
FROM #sendable_universe_searches c1
INNER JOIN #sendable_universe_searches c2 ON c1.user_key = c2.user_key AND c1.job_search_query_lower <> c2.job_search_query_lower
INNER JOIN #search_counts cc1 ON cc1.job_search_query_lower = c1.job_search_query_lower AND cc1.user_computed_state = c1.user_computed_state
INNER JOIN #ranked_search_counts cc2 ON cc2.job_search_query_lower = c2.job_search_query_lower AND cc2.user_computed_state = c2.user_computed_state
WHERE c1.job_search_query_lower IS NOT NULL
AND c2.job_search_query_lower IS NOT NULL
AND cc2.rk <= 1000)
GROUP BY 1,2,3,4;

DELETE FROM #search_jaccard WHERE overlap < 10;

DROP TABLE IF EXISTS #search_recs;
CREATE TABLE #search_recs distkey(user_key) AS
SELECT user_key
, s.user_computed_state
, s.job_search_query_lower
, query2
, ROW_NUMBER() OVER(PARTITION BY user_key ORDER BY overlap DESC) as item_rank
FROM #sendable_universe_searches s
INNER JOIN #search_jaccard cj ON cj.user_computed_state = s.user_computed_state AND cj.query1 = s.job_search_query_lower
;

-------------- CBSA

DROP TABLE IF EXISTS #search_counts_cbsa;
CREATE TABLE #search_counts_cbsa AS
select cbsa_code, job_search_query_lower, count(distinct user_key) users_searched
FROM #sendable_universe_searches
NATURAL JOIN users u
WHERE job_search_query_lower IS NOT NULL
AND job_search_query_lower <> ''
and cbsa_code is not null
and cbsa_mailable_members >= 1000
GROUP BY 1,2;

DROP TABLE IF EXISTS #ranked_search_counts_cbsa;
CREATE TABLE #ranked_search_counts_cbsa AS
SELECT cbsa_code
, job_search_query_lower
, users_searched
, ROW_NUMBER() OVER(PARTITION BY cbsa_code ORDER BY users_searched DESC) rk
FROM #search_counts_cbsa;

DROP TABLE IF EXISTS #search_jaccard_cbsa;
CREATE TABLE #search_jaccard_cbsa AS
SELECT query1
, query2
, cbsa_code
, users_searched_1 search_volume
, 100*count(distinct user_key)::FLOAT/AVG(total_searches) overlap
FROM (
SELECT c1.user_key
, c1.cbsa_code
, c1.job_search_query_lower query1
, c2.job_search_query_lower query2
, cc1.users_searched users_searched_1
, cc2.users_searched users_searched_2
, cc1.users_searched + cc2.users_searched total_searches
FROM #sendable_universe_searches c1
INNER JOIN #sendable_universe_searches c2 ON c1.user_key = c2.user_key AND c1.job_search_query_lower <> c2.job_search_query_lower
INNER JOIN #search_counts_cbsa cc1 ON cc1.job_search_query_lower = c1.job_search_query_lower AND cc1.cbsa_code = c1.cbsa_code
INNER JOIN #ranked_search_counts_cbsa cc2 ON cc2.job_search_query_lower = c2.job_search_query_lower AND cc2.cbsa_code = c2.cbsa_code
WHERE c1.job_search_query_lower IS NOT NULL
AND c2.job_search_query_lower IS NOT NULL
AND cc2.rk <= 1000)
GROUP BY 1,2,3,4;

DELETE FROM #search_jaccard_cbsa WHERE overlap < 10 or search_volume < 5;

DROP TABLE IF EXISTS #search_recs_cbsa;
CREATE TABLE #search_recs_cbsa distkey(user_key) AS
SELECT user_key
, s.cbsa_code
, s.job_search_query_lower
, query2
, ROW_NUMBER() OVER(PARTITION BY user_key ORDER BY overlap DESC) as item_rank
FROM #sendable_universe_searches s
INNER JOIN #search_jaccard_cbsa cj ON cj.cbsa_code = s.cbsa_code AND cj.query1 = s.job_search_query_lower
;

----- for everyone who doesn't have a search or a clickout: recommend searches based on demographics
---- table of total users in MU who searched for query:
DROP TABLE IF EXISTS #user_count_searches;
CREATE TABLE #user_count_searches AS
SELECT job_search_query_lower
, COUNT(DISTINCT user_key) users_searched
FROM #sendable_universe_searches
GROUP BY 1;

------ Break down MU into demographics: age buckets, gender, education level, state; count # of users in each distinct category
DROP TABLE IF EXISTS #demographic_count;
CREATE TABLE #demographic_count AS
SELECT u.user_computed_state
, CASE
WHEN u.user_computed_birth_year_estimate IS NULL THEN 'Null'
WHEN date_part('year',getdate()) - u.user_computed_birth_year_estimate < 25 THEN '25'
WHEN date_part('year',getdate()) - u.user_computed_birth_year_estimate < 45 THEN '45'
WHEN date_part('year',getdate()) - u.user_computed_birth_year_estimate < 65 THEN '65'
ELSE '65+'
END user_age
, CASE
WHEN u.user_computed_gender IS NULL THEN 'Null'
ELSE u.user_computed_gender
END user_computed_gender
, CASE
WHEN u.user_entered_level_of_education IN ('IN_HIGH_SCHOOL','DID_NOT_FINISH_HIGH_SCHOOL','WORKING_TOWARDS_GED','IN_HIGH_SCHOOL_SENIOR','SOME_HIGH_SCHOOL') THEN 'LESS HS'
WHEN u.user_entered_level_of_education IN ('HIGH_SCHOOL_DIPLOMA','GED') THEN 'HS'
WHEN u.user_entered_level_of_education IN ('SOME_COLLEGE','SOME_COLLEGE_1_YEAR','SOME_COLLEGE_2_YEAR','SOME_COLLEGE_3_YEAR','ASSOCIATES_DEGREE') THEN 'SOME COLLEGE'
WHEN u.user_entered_level_of_education IN ('BACHELORS_DEGREE','SOME_GRADUATE') THEN 'BS'
WHEN u.user_entered_level_of_education IN ('MASTERS_DEGREE','DOCTORATE_DEGREE') THEN 'MS'
ELSE 'other'
END education
, COUNT(DISTINCT a.user_key) user_count
FROM mart.jobcase_emailable_universe a
JOIN users u using(user_key)
GROUP BY 1,
2,
3,
4;

-----------------------------------------------------------------------------------------------------------
--- #demographic_searches_count; counts number of users (partitioned by demographic) who searched each job search query
DROP TABLE IF EXISTS #demographic_searches_count;
CREATE TABLE #demographic_searches_count
AS
SELECT u.user_computed_state
, CASE
WHEN u.user_computed_birth_year_estimate IS NULL THEN 'Null'
WHEN date_part('year',getdate()) - u.user_computed_birth_year_estimate < 25 THEN '25'
WHEN date_part('year',getdate()) - u.user_computed_birth_year_estimate < 45 THEN '45'
WHEN date_part('year',getdate()) - u.user_computed_birth_year_estimate < 65 THEN '65'
ELSE '65+'
END user_age
, CASE
WHEN u.user_computed_gender IS NULL THEN 'Null'
ELSE u.user_computed_gender
END user_computed_gender
, CASE
WHEN u.user_entered_level_of_education IN ('IN_HIGH_SCHOOL','DID_NOT_FINISH_HIGH_SCHOOL','WORKING_TOWARDS_GED','IN_HIGH_SCHOOL_SENIOR','SOME_HIGH_SCHOOL') THEN 'LESS HS'
WHEN u.user_entered_level_of_education IN ('HIGH_SCHOOL_DIPLOMA','GED') THEN 'HS'
WHEN u.user_entered_level_of_education IN ('SOME_COLLEGE','SOME_COLLEGE_1_YEAR','SOME_COLLEGE_2_YEAR','SOME_COLLEGE_3_YEAR','ASSOCIATES_DEGREE') THEN 'SOME COLLEGE'
WHEN u.user_entered_level_of_education IN ('BACHELORS_DEGREE','SOME_GRADUATE') THEN 'BS'
WHEN u.user_entered_level_of_education IN ('MASTERS_DEGREE','DOCTORATE_DEGREE') THEN 'MS'
ELSE 'other'
END education
, job_search_query_lower
, COUNT(DISTINCT a.user_key) user_count
FROM mart.jobcase_emailable_universe l
INNER JOIN users u ON l.user_key = u.user_key and u.membership_arrival_created_at is not null
INNER JOIN
(
SELECT user_key
, arrival_key
, REPLACE(REPLACE(REPLACE(REPLACE(LOWER(REGEXP_REPLACE(job_search_query,'[^a-zA-Z\d]','')),'jobs',''),'job',''),'applications',''),'application','') job_search_query_lower
, job_search_created_at
, job_search_key
FROM job_searches
NATURAL JOIN arrivals a
WHERE arrival_created_at > date_add('month',-6,getdate())
and arrival_url not ilike '%JC_Job_Sharing_Hot_Job%'
AND job_search_query IS NOT NULL
AND job_search_query != ''
AND job_search_query != 'keyword'
AND LENGTH(job_search_query) BETWEEN 3 AND 255
) a ON u.user_key = a.user_key
GROUP BY 1,
2,
3,
4,
5;

------------------- STATE

DROP TABLE IF EXISTS #demographic_searches_jaccard;
CREATE TABLE #demographic_searches_jaccard
(
user_computed_state CHAR(2) ENCODE bytedict,
user_age VARCHAR(20) ENCODE runlength,
user_computed_gender VARCHAR(20) ENCODE runlength,
education VARCHAR(20) ENCODE runlength,
job_search_query_lower VARCHAR(255) ENCODE lzo,
user_count_a INT,
user_count_b INT,
user_intersect_b INT,
a_jaccard_b FLOAT,
item_rank INT
);
--- take the top ten searches per demographic, based on the overlap between the users in that demograpic, and the nubmer of overall users who searched for that query
TRUNCATE #demographic_searches_jaccard;
INSERT INTO #demographic_searches_jaccard
SELECT *
FROM (SELECT a.user_computed_state
, a.user_age
, a.user_computed_gender
, a.education
, ab.job_search_query_lower
, a.user_count AS user_count_a ---- number of users in demographic
, b.users_searched AS user_count_b --- number of overall users who searched
, ab.user_count AS a_intersect_b ---- number of users in demographic who searched (overlap between a and b)
, ab.user_count::FLOAT/(a.user_count + b.users_searched - ab.user_count) AS a_jaccard_b ---- jaccard distance between demographic and users who searched for this query
, ROW_NUMBER() OVER (PARTITION BY a.user_computed_state,a.user_age,a.user_computed_gender,a.education ORDER BY ab.user_count /(a.user_count + b.users_searched - ab.user_count)::FLOAT DESC) item_rank ---- rank for this query, for this demographic, based on that jaccard distance
FROM #demographic_count a
INNER JOIN #demographic_searches_count ab
ON a.user_computed_state = ab.user_computed_state
AND a.user_age = ab.user_age
AND a.user_computed_gender = ab.user_computed_gender
AND a.education = ab.education
INNER JOIN #user_count_searches b
ON b.job_search_query_lower = ab.job_search_query_lower
ORDER BY 1,
2,
3,
4,
5)
WHERE item_rank <= 10;

---- Assign each user to a demographic group
DROP TABLE IF EXISTS #mailable_universe_demographics;
CREATE TABLE #mailable_universe_demographics distkey(user_key) AS
SELECT mu.user_key
, u.user_computed_state
, CASE
WHEN u.user_computed_birth_year_estimate IS NULL THEN 'Null'
WHEN date_part('year',getdate()) - u.user_computed_birth_year_estimate < 25 THEN '25'
WHEN date_part('year',getdate()) - u.user_computed_birth_year_estimate < 45 THEN '45'
WHEN date_part('year',getdate()) - u.user_computed_birth_year_estimate < 65 THEN '65'
ELSE '65+'
END user_age
, CASE
WHEN u.user_computed_gender IS NULL THEN 'Null'
ELSE u.user_computed_gender
END user_computed_gender
, CASE
WHEN u.user_entered_level_of_education IN ('IN_HIGH_SCHOOL','DID_NOT_FINISH_HIGH_SCHOOL','WORKING_TOWARDS_GED','IN_HIGH_SCHOOL_SENIOR','SOME_HIGH_SCHOOL') THEN 'LESS HS'
WHEN u.user_entered_level_of_education IN ('HIGH_SCHOOL_DIPLOMA','GED') THEN 'HS'
WHEN u.user_entered_level_of_education IN ('SOME_COLLEGE','SOME_COLLEGE_1_YEAR','SOME_COLLEGE_2_YEAR','SOME_COLLEGE_3_YEAR','ASSOCIATES_DEGREE') THEN 'SOME COLLEGE'
WHEN u.user_entered_level_of_education IN ('BACHELORS_DEGREE','SOME_GRADUATE') THEN 'BS'
WHEN u.user_entered_level_of_education IN ('MASTERS_DEGREE','DOCTORATE_DEGREE') THEN 'MS'
ELSE 'other'
END education
FROM mart.jobcase_emailable_universe mu
JOIN users u using(user_key)
;

----Attach demographic recommendations to each user
DROP TABLE IF EXISTS #demographic_recs;
CREATE TABLE #demographic_recs distkey(user_key) AS
SELECT mu.user_key
, d.job_search_query_lower
, ROW_NUMBER() OVER(PARTITION BY user_key ORDER BY item_rank*RANDOM()) as item_rank
FROM #mailable_universe_demographics mu
INNER JOIN #demographic_searches_jaccard d ON mu.user_computed_state = d.user_computed_state
AND mu.user_age = d.user_age
AND mu.user_computed_gender = d.user_computed_gender
AND mu.education = d.education
;

---- renormalize job search queries
DROP TABLE IF EXISTS #canonical_queries;
CREATE TABLE #canonical_queries AS
SELECT DISTINCT job_search_query
, job_search_query_lower
FROM
(
SELECT job_search_query
, job_search_query_lower
, ROW_NUMBER() OVER (PARTITION BY job_search_query_lower ORDER BY search_count DESC) item_rank
FROM
(
SELECT s.job_search_query
, replace(replace(replace(replace(lower(regexp_replace(s.job_search_query,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '') job_search_query_lower
, COUNT(DISTINCT s.job_search_key) search_count
FROM mart.jobcase_emailable_universe l
NATURAL JOIN
(
SELECT user_key
, arrival_key
, job_search_query
, job_search_created_at
, job_search_key
FROM job_searches
WHERE arrival_created_at > date_add('month',-6,getdate())
AND job_search_query IS NOT NULL
AND job_search_query != ''
AND LENGTH(job_search_query) BETWEEN 3 AND 255
) s
GROUP BY 1,2
)
)
WHERE item_rank = 1 and job_search_query_lower != ''
and job_search_query_lower !='keyword'
and job_search_query_lower is not null
AND job_search_query NOT IN (SELECT q_parameter FROM dbm.keywords_to_remove)
;

/*
Record table for creating variety.
Pull recs history from yesterday to suppress today.
*/

-- compute proxy for number of "available" recommendations i.e. number of user searches
drop table if exists #n_searches;
create table #n_searches distkey(user_key) sortkey(n_searches) as
select user_key
, count(distinct job_search_query_lower) as n_searches
from #sendable_universe_searches
group by 1
;

-- create record table for deduping user-history searches
-- dedup window scales with number of potential user history searches to show
DROP TABLE IF EXISTS #q1;
CREATE TABLE #q1 distkey(user_key) AS
SELECT r.user_key
, keyword AS option
FROM dbm.jc_job_searches_keyword_recommendation_record r
left join #n_searches using(user_key)
WHERE
(
/*
0-2 searches available => dedup last 1 day
3-5 searches available => dedup last 1 day
6-8 searches available => dedup last 2 days
9+ searches available => dedup last 3 days
*/
(
r.send_date = convert_timezone('America/New_York',getdate() -INTERVAL '1 day')::DATE
)
or
(
r.send_date < convert_timezone('America/New_York',getdate())::DATE
and
r.send_date >= dateadd('days', -1 * least(#n_searches.n_searches, 11) / 3, convert_timezone('America/New_York',getdate())::DATE)
)
)
;

-- create record table for deduping non-user-history searches (e.g. jaccard, popular)
DROP TABLE IF EXISTS #r1;
CREATE TABLE #r1 distkey(user_key) AS
SELECT r.user_key
, keyword AS option
FROM dbm.jc_job_searches_keyword_recommendation_record r
left join #n_searches using(user_key)
WHERE
-- enforce deup for last 7d
(
r.send_date < convert_timezone('America/New_York',getdate())::DATE
and
r.send_date >= convert_timezone('America/New_York',getdate() - interval '7 days')::DATE
)
;

----FINAL TABLE of recommendations
---- insert recommendations into final table; ranked by clickout rec > search rec > demo rec, as long as recommendations are NOT in dedup table; take top 4 recommendations
DROP TABLE IF EXISTS #jc_10cat_query_recs;
CREATE TABLE #jc_10cat_query_recs AS
(
SELECT convert_timezone('America/New_York',getdate ())::DATE AS send_date
, user_key
, n.job_search_query
, rec_source
, final_rank
FROM
(
SELECT user_key
, job_search_query_lower
, rec_source
, item_rank
, ROW_NUMBER() OVER (PARTITION BY user_key ORDER BY rec_source,item_rank) final_rank
FROM
(
SELECT d.user_key
, job_search_query_lower
, rec_source
, item_rank
, ROW_NUMBER() OVER (PARTITION BY d.user_key,job_search_query_lower ORDER BY rec_source,item_rank) dedup_rank
FROM
(
SELECT user_key,
job_search_query_lower,
'1_clickouts' AS rec_source,
item_rank
FROM #clickout_recs

UNION
SELECT user_key,
job_search_query_lower,
'2_searches' AS rec_source,
item_rank
FROM #search_recs

UNION
SELECT user_key,
job_search_query_lower,
'3_demo' AS rec_source,
item_rank
FROM #demographic_recs
--location granularity jaccard test

UNION
SELECT user_key,
job_search_query_lower,
'1_cbsa_clickouts' AS rec_source,
item_rank
FROM #clickout_recs_cbsa

UNION
SELECT user_key,
job_search_query_lower,
'2_cbsa_searches' AS rec_source,
item_rank
FROM #search_recs_cbsa
) d
LEFT JOIN #r1 r
ON r.user_key = d.user_key
and d.job_search_query_lower = replace(replace(replace(replace(lower(regexp_replace(r.option,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '')

LEFT JOIN dbm.jc_email_company_suppression_patterns p
ON d.job_search_query_lower ilike p.company_name_pattern
AND p.suppress_from_company_emails = TRUE

WHERE r.user_key IS NULL
AND p.company_name_pattern IS NULL
-- 2019-05-08: suppress WFH keyword recommendations until we can support WFH job metadata and/or phrase matching in Bragi 3.0
and d.job_search_query_lower not ilike '%work%home%'
)
WHERE dedup_rank = 1
)
NATURAL JOIN #canonical_queries n WHERE
final_rank < 5
);

---- Pull into format that listgen query can pull from
DROP TABLE IF EXISTS #jc_10cat_query_recs_user_key;
CREATE TABLE #jc_10cat_query_recs_user_key AS
SELECT user_key,
MAX(CASE WHEN final_rank = 1 THEN job_search_query END) query_1,
MAX(CASE WHEN final_rank = 2 THEN job_search_query END) query_2,
MAX(CASE WHEN final_rank = 3 THEN job_search_query END) query_3,
MAX(CASE WHEN final_rank = 4 THEN job_search_query END) query_4,
MAX(CASE WHEN final_rank = 1 THEN rec_source END) source_1,
MAX(CASE WHEN final_rank = 2 THEN rec_source END) source_2,
MAX(CASE WHEN final_rank = 3 THEN rec_source END) source_3,
MAX(CASE WHEN final_rank = 4 THEN rec_source END) source_4,
MAX(CASE WHEN final_rank = 1 THEN co.company END) company_1,
MAX(CASE WHEN final_rank = 2 THEN co.company END) company_2,
MAX(CASE WHEN final_rank = 3 THEN co.company END) company_3,
MAX(CASE WHEN final_rank = 4 THEN co.company END) company_4
FROM #jc_10cat_query_recs
LEFT JOIN (SELECT company FROM jeffli.jc_company_logos) co
ON ( (REPLACE (LOWER (REPLACE (REPLACE (REPLACE (REPLACE (job_search_query,' ',''),'''',''),'-',''),'&','')),'the','') ilike '%' || co.company || '%'
AND LENGTH (co.company) >= 5)
OR (LOWER (TRIM (job_search_query)) = co.company
AND LENGTH (co.company) <= 4))
GROUP BY 1;

/* best time of day to send */
DROP TABLE if exists #jc_arrival_bucket_clustering_analysis;
CREATE TABLE #jc_arrival_bucket_clustering_analysis
AS
SELECT user_key,
arrival_bucket,
n_arrivals_bucket,
ROW_NUMBER() OVER (PARTITION BY user_key ORDER BY n_arrivals_bucket DESC) AS arrival_bucket_rk,
SUM(n_arrivals_bucket) OVER (PARTITION BY user_key) AS n_arrivals_total
FROM (SELECT u.user_key,
CASE
WHEN DATE_PART(HOUR,arrival_created_at) BETWEEN 19 AND 23 THEN '20'
WHEN DATE_PART(HOUR,arrival_created_at) BETWEEN 0 AND 8 THEN '20'
WHEN DATE_PART(HOUR,arrival_created_at) BETWEEN 9 AND 13 THEN '10'
WHEN DATE_PART(HOUR,arrival_created_at) BETWEEN 14 AND 18 THEN '15'
ELSE NULL
END AS arrival_bucket,
COUNT(DISTINCT arrival_key) AS n_arrivals_bucket
FROM (SELECT mu.user_key,
mu.JC_ENGAGEMENT,
mu.CAREER_ANGST
FROM mart.jobcase_emailable_universe m
INNER JOIN #jc_jobs_list_today l ON l.user_key = m.user_key
Left join dbm.jc_mailable_universe_matrix_classification_a mu on mu.user_key = m.user_key
) u
INNER JOIN (SELECT user_key,
arrival_key,
convert_timezone('America/New_York',arrival_created_at) AS arrival_created_at
FROM arrivals
WHERE arrival_created_at >= getdate() -INTERVAL '30 days'
AND arrival_computed_bot_classification IS NULL) a ON u.user_key = a.user_key
GROUP BY 1,
2);

/*****************
Keyword Recs
*****************/

/*****************
A. Keywords member has searched before ("user_search")
*****************/

-- other member job search queries from last 12mo
DROP TABLE IF EXISTS #union_user_searches_2;
CREATE TABLE #union_user_searches_2 distkey(user_key) sortkey(deduped_rankorder) AS
select user_key
, lowerkey
, keyword
, row_number() over(partition by user_key order by case when sent_yesterday then -1 else n_searches end desc) as rankorder
, rankorder + 40 as deduped_rankorder
, '3_user_job_search_queries' as keyword_type
from
(
select l.user_key
, replace(replace(replace(replace(lower(regexp_replace(job_search_query,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '')
as lowerkey
, job_search_query as keyword
, count(distinct job_search_key) as n_searches
, row_number() over(partition by l.user_key, lowerkey order by n_searches desc) as dedup_rk
, case when #q1.user_key is not null then TRUE else FALSE end as sent_yesterday
from job_searches l
join #jc_jobs_list_today using(user_key)
natural join arrivals
LEFT JOIN #q1
ON l.user_key = #q1.user_key
AND l.job_search_query = #q1.option
where arrival_created_at >= date_add('month',-12,getdate())
and arrival_computed_bot_classification is null
and job_search_query is not null
and job_search_query <> ''
and job_search_reason in ('USER_EXPLICIT','USER_IMPLICIT')
and job_search_jobs_estimate >= 10
and job_search_limit::int >= 5
and arrival_url not ilike '%jc_job_sharing%'
and lower(job_search_query) NOT IN (SELECT distinct LOWER(q_parameter) FROM dbm.keywords_to_remove)
group by 1,2,3,6
)
where dedup_rk = 1
;

-- Combine "user_search" recs, will later limit this group of recs to max 2 in email
drop table if exists #union_user_searches;
create table #union_user_searches distkey(user_key) sortkey(deduped_rankorder) as
select user_key, lowerkey
, regexp_replace(keyword, '[\\s\r\n]+',' ') as keyword
, rankorder
, row_number() over(partition by user_key order by deduped_rankorder) as deduped_rankorder
, keyword_type
from
(
SELECT DISTINCT user_key, lowerkey
, substring(first_value(keyword) over(partition by user_key, lowerkey order by keyword_type, deduped_rankorder rows unbounded preceding), 1, 254) as keyword
, first_value(rankorder) over(partition by user_key, lowerkey order by keyword_type, deduped_rankorder rows unbounded preceding) as rankorder
, first_value(deduped_rankorder) over(partition by user_key, lowerkey order by keyword_type, deduped_rankorder rows unbounded preceding) as deduped_rankorder
, first_value(keyword_type) over(partition by user_key, lowerkey order by keyword_type, deduped_rankorder rows unbounded preceding) as keyword_type
FROM #union_user_searches_2
)
;

/*****************
B. Other Recommendations
*****************/

-- popular job search queries across email traffic
DROP TABLE IF EXISTS #union_other_recs_1;
CREATE TABLE #union_other_recs_1 distkey(user_key) sortkey(deduped_rankorder)
AS
(
SELECT DISTINCT u.user_key
, LOWER(keyword) lowerkey
, keyword
, rankorder
, CASE
WHEN r.user_key IS NOT NULL THEN rankorder + 5003
ELSE rankorder
END AS deduped_rankorder
, '4_popular_email_arrival_queries' AS keyword_type
FROM
(
SELECT u.user_key
FROM #jc_jobs_list_today u
LEFT JOIN dbm.jobcase_suppression_list suppression ON u.user_key = suppression.user_key and suppression.suppress_domain IN ('jobcase.com','percipiomedia.com')
WHERE suppression.user_key IS NULL
) u
CROSS JOIN
(
SELECT keyword
, 60 + ROW_NUMBER() OVER (ORDER BY randweight DESC) rankorder
FROM
(
SELECT keyword
, weighting
, 10 *RANDOM() + weighting*(1.0 /(MAX(weighting) OVER ())) randweight
FROM
(
SELECT keyword
, SUM(clickcount) OVER (PARTITION BY lowerkey) weighting
, ROW_NUMBER() OVER (PARTITION BY lowerkey ORDER BY clickcount DESC) rownum
FROM
(
SELECT f_url_param_utf8(arrival_url,'q') as keyword
, replace(replace(replace(replace(lower(regexp_replace(keyword,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '') as lowerkey
, COUNT(*) clickcount
FROM arrivals a
WHERE arrival_computed_bot_classification IS NULL
AND arrival_computed_device_type <> 'BOT'
AND arrival_url LIKE '%q=%'
AND arrival_created_at >= convert_timezone('America/New_York','UTC','today'::TIMESTAMP-INTERVAL '14 days')
AND arrival_created_at < convert_timezone('America/New_York','UTC','today'::TIMESTAMP)
AND arrival_computed_traffic_source = 'Percipio Email'
AND arrival_url NOT LIKE '%view_job_detail%'
GROUP BY 1,2
) x
WHERE lowerkey NOT IN ('','fulltime','parttime','immediate','seasonal','fullbenefits','2013','2014','2015','bachelorsdegree','mastersdegree','associatesdegree','highschooldiploma','ged'
, 'full time','part time','immediate','seasonal','full benefits','2013','2014','2015','bachelors degree','masters degree','associates degree','highschool diploma','ged')
AND lowerkey NOT ilike '%\\%%'
AND lowerkey NOT in (SELECT lower(q_parameter) from dbm.keywords_to_remove)
AND lowerkey NOT IN (SELECT replace(replace(replace(replace(lower(regexp_replace(q_parameter,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '') FROM dbm.keywords_to_remove)
)
WHERE rownum = 1
AND keyword NOT ilike '%\\%%'
AND keyword NOT IN (SELECT q_parameter FROM dbm.keywords_to_remove)
ORDER BY weighting DESC
LIMIT 250
)
ORDER BY randweight DESC LIMIT 12
) q
LEFT JOIN #q1 r
ON u.user_key = r.user_key
AND q.keyword = r.option
);

DROP TABLE IF EXISTS #union_other_recs_1a;
CREATE TABLE #union_other_recs_1a distkey(user_key)
AS
SELECT DISTINCT user_key
, LOWER(a.keyword) lowerkey
, a.keyword
, rankorder
, CASE
WHEN user_key IS NOT NULL THEN rankorder + 5003
ELSE rankorder
END AS deduped_rankorder
, '4_popular_email_arrival_queries' AS keyword_type
FROM #union_other_recs_1 a
;

-- take randomized list of 10 popular keywords in cbsa
drop table if exists #popular_cbsa_queries;
create table #popular_cbsa_queries as
select *
, row_number() over(partition by cbsa_code order by rand_weight desc) as rk
from
(
select cbsa_code
, job_search_query_lower
, users_searched
, RANDOM() + 0.25 * users_searched*(1.0 /(MAX(users_searched) OVER (PARTITION BY cbsa_code))::float) as rand_weight
from
(
select cbsa_code
, job_search_query_lower
, users_searched
from #search_counts_cbsa
where job_search_query_lower NOT IN (SELECT DISTINCT replace(replace(replace(replace(lower(regexp_replace(q_parameter,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '') FROM dbm.keywords_to_remove)
)
)
order by rk
;

delete
from #popular_cbsa_queries
where rk > 28
;

-- take randomized list of 10 popular keywords in state
drop table if exists #popular_state_queries;
create table #popular_state_queries as
select *
, row_number() over(partition by user_computed_state order by rand_weight desc) as rk
from
(
select user_computed_state
, job_search_query_lower
, users_searched
, RANDOM() + 0.25*users_searched*(1.0 /(MAX(users_searched) OVER (PARTITION BY user_computed_state)::float)) as rand_weight
from
(
select user_computed_state
-- , cbsa_code
, job_search_query_lower
, users_searched
from #search_counts
where job_search_query_lower NOT IN (SELECT DISTINCT replace(replace(replace(replace(lower(regexp_replace(q_parameter,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '') FROM dbm.keywords_to_remove)
)
)
;

delete
from #popular_state_queries
where rk > 28
;

drop table if exists #member_cbsas;
create table #member_cbsas distkey(user_key) as
select mul.user_key, mul.state, c.cbsa_code, c.cbsa_title
from analytics.zip_cbsa c
join dbm.jc_mart_emailable_universe_locations mul on c.zipcode = mul.zip
;

DROP TABLE IF EXISTS #union_other_recs_1b;
CREATE TABLE #union_other_recs_1b distkey(user_key) as
select q.*
from
(
select mu.user_key
, q.job_search_query_lower as lowerkey
, cq.job_search_query as keyword
, rk as rankorder
, 80 + rk as deduped_rankorder
, '4__popular_state_queries' as keyword_type
FROM mart.jobcase_emailable_universe mu
INNER JOIN #jc_jobs_list_today l using(user_key)
JOIN #member_cbsas c using(user_key)
JOIN #popular_state_queries q on q.user_computed_state = c.state
NATURAL JOIN #canonical_queries cq
WHERE q.rk <= 28

UNION

select mu.user_key
, q.job_search_query_lower as lowerkey
, cq.job_search_query as keyword
, rk as rankorder
, 50 + rk as deduped_rankorder
, '4__popular_cbsa_queries' as keyword_type
FROM mart.jobcase_emailable_universe mu
INNER JOIN #jc_jobs_list_today l using(user_key)
JOIN #member_cbsas c using(user_key)
JOIN #popular_cbsa_queries q on q.cbsa_code = c.cbsa_code
NATURAL JOIN #canonical_queries cq
WHERE q.rk <= 28
) q
LEFT JOIN #r1 r
ON q.user_key = r.user_key
AND q.keyword = r.option
where r.user_key is null
;

-- combine all of the recs together & dedup on lowerkey for a user
-- 3max user_search, fill in the rest with other_recs
DROP TABLE IF EXISTS #union_final;
CREATE TABLE #union_final distkey(user_key)
AS
(
SELECT DISTINCT user_key
, lowerkey
, substring(first_value(regexp_replace(keyword, '[\\s\r\n]+',' ')) over(partition by user_key, lowerkey order by keyword_type, deduped_rankorder rows unbounded preceding), 1, 254) as keyword
, first_value(rankorder) over(partition by user_key, lowerkey order by keyword_type, deduped_rankorder rows unbounded preceding) as rankorder
, first_value(deduped_rankorder) over(partition by user_key, lowerkey order by keyword_type, deduped_rankorder rows unbounded preceding) as deduped_rankorder
, first_value(keyword_type) over(partition by user_key, lowerkey order by keyword_type, deduped_rankorder rows unbounded preceding) as keyword_type
FROM
(
SELECT *
FROM
(
SELECT *
FROM #union_user_searches
WHERE deduped_rankorder <= 3)

UNION
(
SELECT *
FROM #union_other_recs_1a)

UNION
(
SELECT *
FROM #union_other_recs_1b)

) q
LEFT JOIN dbm.jc_email_company_suppression_patterns p
ON q.keyword ilike p.company_name_pattern
AND p.suppress_from_company_emails = TRUE

WHERE p.company_name_pattern IS NULL
-- 2019-05-08: suppress WFH keyword recommendations until we can support WFH job metadata and/or phrase matching in Bragi 3.0
and q.keyword not ilike '%work%home%'
)
;

DROP TABLE IF EXISTS #l4;
CREATE TABLE #l4 distkey(user_key)
AS
(SELECT #union_final.user_key,
TRIM(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(keyword,'<',''),'>',''),'|',''),'\\',''),'/','')) AS keyword,
ROW_NUMBER() OVER (PARTITION BY #union_final.user_key ORDER BY CASE WHEN SUBSTRING(MD5(#union_final.user_key),12,1) IN ('0','1','2','3','4','5','6','7') THEN deduped_rankorder ELSE deduped_rankorder END) topN,
rankorder,
deduped_rankorder,
keyword_type
FROM #union_final);

DROP TABLE IF EXISTS #l5;
CREATE TABLE #l5 distkey(user_key)
AS
(SELECT user_key,
MAX(CASE WHEN topn = 1 THEN keyword ELSE NULL END) data001,
MAX(CASE WHEN topn = 1 THEN company ELSE NULL END) data002,
MAX(CASE WHEN topn = 2 THEN keyword ELSE NULL END) data003,
MAX(CASE WHEN topn = 2 THEN company ELSE NULL END) data004,
MAX(CASE WHEN topn = 3 THEN keyword ELSE NULL END) data005,
MAX(CASE WHEN topn = 3 THEN company ELSE NULL END) data006,
MAX(CASE WHEN topn = 4 THEN keyword ELSE NULL END) data007,
MAX(CASE WHEN topn = 4 THEN company ELSE NULL END) data008,
MAX(CASE WHEN topn = 5 THEN keyword ELSE NULL END) data009,
MAX(CASE WHEN topn = 5 THEN company ELSE NULL END) data010,
MAX(CASE WHEN topn = 6 THEN keyword ELSE NULL END) data011,
MAX(CASE WHEN topn = 6 THEN company ELSE NULL END) data012,
MAX(CASE WHEN topn = 7 THEN keyword ELSE NULL END) data013,
MAX(CASE WHEN topn = 7 THEN company ELSE NULL END) data014,
MAX(CASE WHEN topn = 8 THEN keyword ELSE NULL END) data015,
MAX(CASE WHEN topn = 8 THEN company ELSE NULL END) data016,
MAX(CASE WHEN topn = 9 THEN keyword ELSE NULL END) data017,
MAX(CASE WHEN topn = 9 THEN company ELSE NULL END) data018,
MAX(CASE WHEN topn = 10 THEN keyword ELSE NULL END) data019,
MAX(CASE WHEN topn = 10 THEN company ELSE NULL END) data020,
MAX(CASE WHEN topn = 1 THEN keyword_type ELSE NULL END) keyword_type_1,
MAX(CASE WHEN topn = 2 THEN keyword_type ELSE NULL END) keyword_type_2,
MAX(CASE WHEN topn = 3 THEN keyword_type ELSE NULL END) keyword_type_3,
MAX(CASE WHEN topn = 4 THEN keyword_type ELSE NULL END) keyword_type_4,
MAX(CASE WHEN topn = 5 THEN keyword_type ELSE NULL END) keyword_type_5,
MAX(CASE WHEN topn = 6 THEN keyword_type ELSE NULL END) keyword_type_6,
MAX(CASE WHEN topn = 7 THEN keyword_type ELSE NULL END) keyword_type_7,
MAX(CASE WHEN topn = 8 THEN keyword_type ELSE NULL END) keyword_type_8,
MAX(CASE WHEN topn = 9 THEN keyword_type ELSE NULL END) keyword_type_9,
MAX(CASE WHEN topn = 10 THEN keyword_type ELSE NULL END) keyword_type_10
FROM #l4
LEFT JOIN (SELECT company FROM jeffli.jc_company_logos) co
ON ( (REPLACE (LOWER (REPLACE (REPLACE (REPLACE (REPLACE (#l4.keyword,' ',''),'''',''),'-',''),'&','')),'the','') ilike '%' || co.company || '%'
AND LENGTH (co.company) >= 5)
OR (LOWER (TRIM (#l4.keyword)) = co.company
AND LENGTH (co.company) <= 4))
WHERE topN <= 12
GROUP BY 1);

DROP TABLE IF EXISTS #l6;
CREATE TABLE #l6 distkey(user_key)
AS
(SELECT user_key,
data001,
data002,
data003,
data004,
data005,
data006,
data007,
data008,
data009,
data010,
data011,
data012,
data013,
data014,
data015,
data016,
data017,
data018,
data019,
data020,
keyword_type_1,
keyword_type_2,
keyword_type_3,
keyword_type_4,
keyword_type_5,
keyword_type_6,
keyword_type_7,
keyword_type_8,
keyword_type_9,
keyword_type_10
FROM #l5);

DROP TABLE IF EXISTS #jc_jobs_test_list_all;

----THIS IS THE CONTROL
CREATE TABLE #jc_jobs_test_list_all
distkey(user_key) AS
SELECT #l6.user_key,
COALESCE('T' ||t.arrival_bucket,'T15') AS segment,
data001,
data002,
data003,
data004,
data005,
data006,
(data007)::varchar(4000),
(data008)::varchar(4000),
CASE
WHEN #l6.user_key IN (SELECT user_key FROM dbm.jc_specific_jobs) THEN 'TRUE'
ELSE 'FALSE'
END AS data009,
initcap(mu.city) AS data010,
mu.state AS data011,
keyword_type_1 AS data012,
keyword_type_2 AS data013,
keyword_type_3 AS data014,
(keyword_type_4)::varchar(4000) AS data015
FROM #l6
LEFT JOIN users u ON #l6.user_key = u.user_key and u.membership_arrival_created_at is not null
LEFT JOIN dbm.jc_mart_emailable_universe_locations mu ON u.user_key = mu.user_key
LEFT JOIN (SELECT user_key,
arrival_bucket,
n_arrivals_total,
n_arrivals_bucket / n_arrivals_total::FLOAT AS percent_of_total_arrivals
FROM #jc_arrival_bucket_clustering_analysis
WHERE arrival_bucket_rk = 1) t ON u.user_key = t.user_key
LEFT JOIN (SELECT DISTINCT email_address
FROM dbm.jc_prefs_zeta
WHERE offer_id = '2') osu_z ON osu_z.email_address = u.user_entered_email
LEFT JOIN (SELECT DISTINCT emailaddress
FROM dbm.jobcase_preferences
WHERE option_id IN ('3','4')
AND offer_id = '2') osu_et ON osu_et.emailaddress = u.user_entered_email
WHERE osu_z.email_address IS NULL
AND osu_et.emailaddress IS NULL
;

------------ Alternating Creative Variant Override
delete from dbm.jc_10cat_creative_alternation_test_record where send_date = convert_timezone('America/New_York', getdate())::date;
insert into dbm.jc_10cat_creative_alternation_test_record
select distinct l.user_key
, convert_timezone('America/New_York', getdate())::date as send_date
, datediff('days', r.first_profile_send_date, convert_timezone('America/New_York', getdate())::date) as days_since_first_profile_send_date
, case when substring(md5('e5ac' || md5(l.user_key)), 2, 1) < '4' then 'CONTROL'
when substring(md5('e5ac' || md5(l.user_key)), 2, 1) < '8' then 'TEST_J4'
when substring(md5('e5ac' || md5(l.user_key)), 2, 1) < 'c' then 'TEST_J2'
else 'TEST_J1'
end as test_group
, FALSE as override
from #jc_jobs_test_list_all l
join dbm.jc_job_searches_profile_variant_record r on l.user_Key = r.user_key
where datediff('days', r.first_profile_send_date, convert_timezone('America/New_York', getdate())::date) >= 4
;

-- starting day 4 after first profile variant send, start alternating variants
update dbm.jc_10cat_creative_alternation_test_record
set override = TRUE
where send_date = convert_timezone('America/New_York', getdate())::date
and days_since_first_profile_send_date % 2 = 0
;

update #jc_jobs_test_list_all
set data009 = 'FALSE'
where user_key in
(
select user_key
from dbm.jc_10cat_creative_alternation_test_record
where send_date = convert_timezone('America/New_York', getdate())::date
and override = TRUE
)
;

------------ end Alternating Creative Variant Override

delete from dbm.jc_10Cat_query_record where send_date = convert_timezone('America/New_York',getdate ())::DATE;
insert into dbm.jc_10Cat_query_record
(select
user_key, data012 as data043, data013 as data044, data014 as data045, data015 as data046, convert_timezone('America/New_York',getdate ())::DATE AS send_date
from #jc_jobs_test_list_all);

Update #jc_jobs_test_list_all SET
data001 = qr.query_1,
data002 = qr.company_1,
data012 = qr.source_1
from #jc_jobs_test_list_all l
inner join #jc_10cat_query_recs_user_key qr ON qr.user_key = l.user_key
where l.user_key in (select l1.user_key
from #jc_jobs_test_list_all l1
where l1.data012 in ('4_popular_email_arrival_queries','4__popular_cbsa_queries','4__popular_state_queries')
)
and qr.query_1 <> l.data007
and qr.query_1 <> l.data005
and qr.query_1 <> l.data003
and qr.query_1 <> l.data001
and qr.query_1 is not null;

Update #jc_jobs_test_list_all SET
data003 = qr.query_2,
data004 = qr.company_2,
data013 = qr.source_2
from #jc_jobs_test_list_all l
inner join #jc_10cat_query_recs_user_key qr ON qr.user_key = l.user_key
where l.user_key in (select l1.user_key
from #jc_jobs_test_list_all l1
where l1.data013 in ('4_popular_email_arrival_queries','4__popular_cbsa_queries','4__popular_state_queries')
)
and qr.query_2 <> l.data007
and qr.query_2 <> l.data005
and qr.query_2 <> l.data003
and qr.query_2 <> l.data001
and qr.query_2 is not null;

Update #jc_jobs_test_list_all SET
data005 = qr.query_3,
data006 = qr.company_3,
data014 = qr.source_3
from #jc_jobs_test_list_all l
inner join #jc_10cat_query_recs_user_key qr ON qr.user_key = l.user_key
where l.user_key in (select l1.user_key
from #jc_jobs_test_list_all l1
where l1.data014 in ('4_popular_email_arrival_queries','4__popular_cbsa_queries','4__popular_state_queries')
)
and qr.query_3 <> l.data007
and qr.query_3 <> l.data005
and qr.query_3 <> l.data003
and qr.query_3 <> l.data001
and qr.query_3 is not null;

Update #jc_jobs_test_list_all SET
data015 = qr.source_4,
data007 = qr.query_4,
data008 = qr.company_4
from #jc_jobs_test_list_all l
inner join #jc_10cat_query_recs_user_key qr ON qr.user_key = l.user_key
where l.user_key in (select l1.user_key
from #jc_jobs_test_list_all l1
where l1.data015 in ('4_popular_email_arrival_queries','4__popular_cbsa_queries','4__popular_state_queries')
)
and qr.query_4 <> l.data007
and qr.query_4 <> l.data005
and qr.query_4 <> l.data003
and qr.query_4 <> l.data001
and qr.query_4 is not null;

DELETE
FROM #jc_jobs_test_list_all
WHERE data001 IN (SELECT q_parameter FROM dbm.keywords_to_remove)
OR data003 IN (SELECT q_parameter FROM dbm.keywords_to_remove)
OR data005 IN (SELECT q_parameter FROM dbm.keywords_to_remove)
OR data007 IN (SELECT q_parameter FROM dbm.keywords_to_remove);

/* update record of keyword recs and profile variants */
DELETE FROM dbm.jc_job_searches_keyword_recommendation_record where send_date = convert_timezone('America/New_York', getdate())::date;

INSERT INTO dbm.jc_job_searches_keyword_recommendation_record
SELECT user_key
, convert_timezone('America/New_York',getdate ())::DATE as send_date
, data009 as is_profile_variant
, CAST(data001 AS VARCHAR(254)) as keyword
, data012 as rec_source
, 1 as rk
FROM #jc_jobs_test_list_all;

INSERT INTO dbm.jc_job_searches_keyword_recommendation_record
SELECT user_key
, convert_timezone('America/New_York',getdate ())::DATE as send_date
, data009 as is_profile_variant
, CAST(data003 AS VARCHAR(254)) as keyword
, data013 as rec_source
, 2 as rk
FROM #jc_jobs_test_list_all;

INSERT INTO dbm.jc_job_searches_keyword_recommendation_record
SELECT user_key
, convert_timezone('America/New_York',getdate ())::DATE as send_date
, data009 as is_profile_variant
, CAST(data005 AS VARCHAR(254)) as keyword
, data014 as rec_source
, 3 as rk
FROM #jc_jobs_test_list_all;

INSERT INTO dbm.jc_job_searches_keyword_recommendation_record
SELECT user_key
, convert_timezone('America/New_York',getdate ())::DATE as send_date
, data009 as is_profile_variant
, CAST(data007 AS VARCHAR(254)) as keyword
, data015 as rec_source
, 4 as rk
FROM #jc_jobs_test_list_all;

/* update record of member's first profile variant, used for creative alternation */
INSERT INTO dbm.jc_job_searches_profile_variant_record
SELECT user_key, convert_timezone('America/New_York',getdate ())::DATE as first_profile_send_date
FROM #jc_jobs_test_list_all
WHERE user_key NOT IN (SELECT user_key FROM dbm.jc_job_searches_profile_variant_record)
AND data009 = 'TRUE'
;

-- once deletes are made, update the list with the concated list of keywords, companies, etc
Update #jc_jobs_test_list_all SET
data015 = l.data015||'|'||qr.keyword_type_5||'|'||qr.keyword_type_6||'|'||qr.keyword_type_7||'|'||qr.keyword_type_8||'|'||qr.keyword_type_9||'|'||qr.keyword_type_10,
data007 = l.data007||'|'||qr.data009||'|'||qr.data011||'|'||qr.data013||'|'||qr.data015||'|'||qr.data017||'|'||qr.data019
from #jc_jobs_test_list_all l
inner join #l6 qr ON qr.user_key = l.user_key
;

delete from dbm.jc_10Cat_multi_cat_test where send_date = convert_timezone('America/New_York', getdate())::date;
insert into dbm.jc_10Cat_multi_cat_test
(
select
distinct l.user_key
,convert_timezone('America/New_York', getdate())::date as send_date
,count(distinct l4.keyword) as keywords_available
from
#jc_jobs_test_list_all l
inner join #l4 l4 on l4.user_key = l.user_key
group by 1,2
)
;

drop table if exists #email_arrivals;
create table #email_arrivals as
 SELECT
   mu.user_key
 , DATEDIFF('DAYS', MAX(arrival_created_at),GETDATE()) AS dslea
 , NVL(DATEDIFF('DAYS', MAX(CASE WHEN arrival_application <> 'jobcase.com' THEN arrival_created_at END),GETDATE()), 9999) AS ph_dslea
 , NVL(DATEDIFF('DAYS', MAX(CASE WHEN arrival_application = 'jobcase.com' THEN arrival_created_at END),GETDATE()), 9999) AS jc_dslea
 , MIN(email_domain_group) AS email_domain_group
 FROM
   public.arrivals a
   NATURAL JOIN users u
   JOIN mart.jobcase_emailable_universe mu ON u.user_key = mu.user_key
 WHERE
   a.arrival_computed_traffic_type = 'Email'
   AND a.arrival_computed_bot_classification IS NULL
   AND a.arrival_created_at >= GETDATE()::DATE - INTERVAL '100 DAYS'
   AND u.membership_arrival_created_at IS NOT NULL
 GROUP BY 1
 ;

drop table if exists #users_to_keep;
create table #users_to_keep as
(
 select
 distinct user_key
 from
 #email_arrivals
 where dslea <= 25
)
;


drop table if exists #users_to_delete;
create table #users_to_delete as
select distinct user_key
from listgen.jc_jobs_test_list_all
  where
  user_key not in (select distinct user_key from #users_to_keep)
  and user_key in (select distinct user_key from dbm.jobcase_email_content_cadence where cadence_email_domain_group = 'MSN' and tplus_type not in ('tp-dslr-', 'tp-dslrr-') )
  ;


DROP TABLE IF EXISTS listgen.jc_jobs_test_list_all;
CREATE TABLE listgen.jc_jobs_test_list_all distkey(user_key) as
SELECT * FROM #jc_jobs_test_list_all
;

/* MAIN SQL */
(
select l.*
from listgen.jc_jobs_test_list_all l
join mart.jobcase_emailable_universe mu on mu.user_key = l.user_key
left join dbm.compliance_opt_out_events_subset oo
on l.user_key = oo.user_key
and compliance_opt_out_event_entities = ';Jobcase'
and compliance_opt_out_event_groupings= ';Jobcase'
and compliance_opt_out_event_domains = ';jobcase.com'
and compliance_opt_out_event_lines_of_business = ';EMPLOYMENT'
and compliance_opt_out_event_topics = ';JOB'
and compliance_opt_out_event_topics_level_2 = ';POPULAR_JOB_SEARCH'
where true
-- removed people allocated to new ET IP Warmup effective 2018-06-11
and mu.user_key not in (select user_key from dbm.jc_ip_warmup where classification_date = convert_timezone('America/New_York', getdate())::date and assigned_ip in ('ET_Jobcase_Alternate','SG_Jobcase','SG_Jobcase_Alternate'))
and mu.user_key not in (select user_key from dbm.jc_ip_warmup where classification_date = convert_timezone('America/New_York', getdate())::date and assigned_ip = 'MG_Jobcase' and user_computed_email_domain_group != 'GMAIL')
and mu.user_key not in (select user_key from dbm.jc_ip_warmup where classification_date = convert_timezone('America/New_York', getdate())::date and assigned_ip = 'MG_Jobcase' and substring(md5(concat('ET_10CAT', md5(user_key))), 1,1) >= '8' and user_computed_email_domain_group = 'GMAIL')
and oo.user_key is null
)

/* POST SQL */
