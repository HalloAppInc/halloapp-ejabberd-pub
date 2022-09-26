%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_reporting_tests).
-author("josh").

-include("reporting.hrl").
-include("server.hrl").
-include("tutil.hrl").

-define(REPORTER_UID, <<"1">>).
-define(REPORTED_UID, <<"2">>).
-define(CONTENT_ID, <<"3">>).

setup() ->
    tutil:setup([
        proto,
        {meck, ha_events, log_event, fun(_, _) -> ok end}
    ]).

iq_testset(_) ->
    UserIQ = get_iq(user),
    PostIQ = get_iq(post),
    UnknownIQ = get_iq(unknown),
    [
        ?_assertEqual(result_iq(UserIQ), mod_reporting:process_local_iq(UserIQ)),
        ?_assertEqual(1, meck:num_calls(ha_events, log_event, [?USER_REPORT_NS, event_map(user)])),
        ?_assertEqual(result_iq(PostIQ), mod_reporting:process_local_iq(PostIQ)),
        ?_assertEqual(1, meck:num_calls(ha_events, log_event, [?USER_REPORT_NS, event_map(post)])),
        ?_assertEqual(result_iq(UnknownIQ), mod_reporting:process_local_iq(UnknownIQ)),
        ?_assertEqual(1, meck:num_calls(ha_events, log_event, [?USER_REPORT_NS, event_map(unknown)]))
    ].

get_iq(Type) ->
    #pb_iq{
        from_uid = ?REPORTER_UID,
        payload = #pb_report_user_content{
            type = Type,
            uid = ?REPORTED_UID,
            content_id = ?CONTENT_ID
        }
    }.

result_iq(IQ) ->
    pb:make_iq_result(IQ).

event_map(Type) ->
    EventMap = #{
        report_type => Type,
        reporting_uid => ?REPORTER_UID,
        reported_uid => ?REPORTED_UID
    },
    case Type of
        user -> EventMap;
        _ -> EventMap#{content_id => ?CONTENT_ID}
    end.

