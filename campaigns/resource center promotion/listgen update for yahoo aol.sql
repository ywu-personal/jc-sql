delete from dbm.jc_standalone_promotion_email_record where send_date = convert_timezone('America/New_York',getdate())::DATE;

insert into dbm.jc_standalone_promotion_email_record
select
distinct cc.user_key as user_key
, convert_timezone('America/New_York',getdate())::DATE as send_date
, 'Lenin P. (via Jobcase)' as sender_profile_name
,'Getting Hired' as promotion_content_specific
from dbm.jobcase_email_content_cadence cc
natural join users
left join dbm.jc_standalone_promotion_email_record pr
on pr.user_key = cc.user_key and pr.promotion_content_specific = 'Getting Hired' and pr.send_date >= convert_timezone('America/New_York',getdate())::DATE - interval '30 days'
where
(
cc.user_key in (select distinct user_key
from communications
where communication_sent_time >= getdate() - interval '30 days'
and
(
(communication_open_time_initial >= getdate() - interval '7 days'
and communication_to_address_email_domain_group in ('GMAIL', 'MSN')
)
or
(communication_open_time_initial >= getdate() - interval '14 days'
and communication_to_address_email_domain_group not in ('GMAIL', 'MSN')
)
)
and communication_sending_domain = 'post.jobcase.com'
and communication_to_address_email_domain_group in ('YAHOO', 'AOL')
)
or
cc.user_key in (select distinct a.user_key
from arrivals a
left join users u on u.user_key = a.user_key
where arrival_created_at >= getdate() - interval '30 days'
and arrival_application = 'jobcase.com'
and arrival_computed_traffic_type = 'Email'
and u.user_computed_email_domain_group in ('YAHOO', 'AOL')
)
)
and cc.send_date = convert_timezone('America/New_York',getdate())::DATE
and cc.tplus_type not in ('tp-dslr-ne-', 'tp-dslrr-ne-')
and user_computed_state is not null
-- remove users who have received the resource center email in the past month and set up send duration 5/19-5/27
and pr.user_key is null
-- and convert_timezone('America/New_York',getdate())::DATE > '2020-05-18' and convert_timezone('America/New_York',getdate())::DATE <= '2020-05-27'
order by random()
limit 40000
;
