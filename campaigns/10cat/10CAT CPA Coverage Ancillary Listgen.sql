/***10CAT CPA Coverage Rank Test 0705*/
-- cpa and coverage table
-- generate kw historical cpa table with 14day lookback window

DROP TABLE IF EXISTS #job_clickout_revenue_5day;
CREATE TABLE #job_clickout_revenue_5day AS
SELECT user_key, arrival_key
                 , SUM(job_search_clickout_revenue) job_revenue
                 , count(distinct case when job_search_clickout_disposition = 'SUCCESS' AND job_search_clickout_status = 'POSTED' THEN job_search_clickout_key END) job_clicks
          FROM job_search_clickouts
            NATURAL JOIN arrivals
          WHERE arrival_computed_bot_classification IS NULL
          AND   arrival_application = 'jobcase.com'
          and job_search_clickout_disposition = 'SUCCESS'
                                        and job_search_clickout_status = 'POSTED'
          AND  arrival_created_at >= date_add('day',-14,getdate())
          GROUP BY 1,2;

DELETE FROM dbm.cpa_mapping_5day WHERE 1;
INSERT INTO dbm.cpa_mapping_5day
SELECT * FROM
(
select
distinct job_search_query
, count(distinct js.arrival_key) as arrivals
, sum(jcr.job_clicks) as jobclicks
, count(distinct case when jcr.job_clicks >0 then js.arrival_key end) as arrivals_clicked
, sum(coalesce(jcr.job_clicks, 0))/(count(distinct js.arrival_key)+0.0001) as cpa
, arrivals_clicked/(arrivals+0.0001) as capa
from arrivals a
inner join (select distinct job_search_query, arrival_key
from
job_searches
where job_search_query is not null
and job_search_query <> ''
and job_search_limit::int = 50
and job_search_rule_id = '107'
) js on js.arrival_key = a.arrival_key
left join #job_clickout_revenue_5day jcr
  on jcr.arrival_key = a.arrival_key and jcr.user_key = a.user_key
where arrival_created_at >= date_add('day',-14,getdate())
and arrival_computed_bot_classification is null
and arrival_url not ilike '%jc_job_sharing%'
group by 1
order by arrivals desc)
where arrivals >= 50;


DELETE FROM dbm.search_coverage_5day WHERE 1;
INSERT INTO dbm.search_coverage_5day
SELECT * FROM(
SELECT
job_search_query
, count(DISTINCT job_search_key) AS job_searches
, count(DISTINCT CASE WHEN search_yielded_matching_listing THEN job_search_key END) AS job_searches_yielded_matching_listing
, job_searches_yielded_matching_listing::float / job_searches AS coverage
FROM(
SELECT
job_search_query
, job_search_key
, CASE WHEN count(DISTINCT CASE WHEN job_search_impression_job_title ILIKE '%' || job_search_query || '%'
OR job_search_impression_company_name ILIKE '%' || job_search_query || '%'
OR job_search_query ILIKE '%' || job_search_impression_company_name || '%'
OR job_search_query ILIKE '%' || job_search_impression_job_title || '%'
THEN job_search_key END) = 0 THEN FALSE ELSE TRUE END AS search_yielded_matching_listing
FROM job_searches
Natural join job_search_impressions
natural join arrivals
WHERE job_search_query IS NOT NULL
	AND job_search_created_at >= date_add('day',-14,getdate())
	and job_search_limit = 50
	and arrival_computed_traffic_type = 'Email'
  and arrival_url not ilike '%jc_job_sharing%'
  and job_search_rule_id = '107'
GROUP BY 1,2)
GROUP BY 1
ORDER BY 2 DESC)
WHERE job_searches >= 50;

---- renormalize job search queries

DELETE FROM dbm.canonical_queries_10cat WHERE 1;
INSERT INTO dbm.canonical_queries_10cat
SELECT DISTINCT job_search_query
, job_search_query_lower
FROM(
SELECT job_search_query
, job_search_query_lower
, ROW_NUMBER() OVER (PARTITION BY job_search_query_lower ORDER BY search_count DESC) item_rank
FROM(
SELECT s.job_search_query
, replace(replace(replace(replace(lower(regexp_replace(s.job_search_query,'[^a-zA-Z\d]', '')), 'jobs', ''), 'job', ''), 'applications', ''), 'application', '') job_search_query_lower
, COUNT(DISTINCT s.job_search_key) search_count
FROM mart.jobcase_emailable_universe l
NATURAL JOIN(
SELECT user_key
, arrival_key
, job_search_query
, job_search_created_at
, job_search_key
FROM job_searches
WHERE arrival_created_at > date_add('month',-6,getdate())
AND job_search_query IS NOT NULL
AND job_search_query != ''
AND LENGTH(job_search_query) BETWEEN 3 AND 255) s
GROUP BY 1,2))
WHERE item_rank = 1 and job_search_query_lower != ''
and job_search_query_lower !='keyword'
and job_search_query_lower is not null
AND job_search_query NOT IN (SELECT q_parameter FROM dbm.keywords_to_remove);

grant all on dbm.canonical_queries_10cat to listgen, audience_resolver, group dbm_writer, group dbm_reader;
-- grant all on dbm.job_clickout_revenue_5day to listgen, audience_resolver, group dbm_writer, group dbm_reader;
grant all on dbm.search_coverage_5day to listgen, audience_resolver, group dbm_writer, group dbm_reader;
grant all on dbm.cpa_mapping_5day to listgen, audience_resolver, group dbm_writer, group dbm_reader;
