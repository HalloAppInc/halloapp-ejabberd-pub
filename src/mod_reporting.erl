%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_reporting).
-author("josh").

-include("logger.hrl").
-include("reporting.hrl").
-include("server.hrl").

%% gen_mod callbacks
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).
-export([process_local_iq/1]).

%%====================================================================
%% gen_mod functions
%%====================================================================

start(_Host, _Opts) ->
    gen_iq_handler:add_iq_handler(ejabberd_local, halloapp, pb_report_user_content, ?MODULE, process_local_iq),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_report_user_content, ?MODULE, process_local_iq),
    ok.

stop(_Host) ->
    gen_iq_handler:remove_iq_handler(ejabberd_local, halloapp, pb_report_user_content),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_report_user_content),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% IQ handler
%%====================================================================

process_local_iq(#pb_iq{from_uid = ReportingUid, payload =
        #pb_report_user_content{type = Type, uid = ReportedUid, content_id = ContentId}} = IQ) ->
    ?INFO("~s report from ~s: ~s | ~s", [Type, ReportingUid, ReportedUid, ContentId]),
    case Type of
        post -> log_post_report(ReportingUid, ReportedUid, ContentId);
        user -> log_user_report(ReportingUid, ReportedUid);
        _ -> log_unknown_report(ReportingUid, ReportedUid, ContentId)
    end,
    pb:make_iq_result(IQ).

%%====================================================================
%% Internal functions
%%====================================================================

log_user_report(ReportingUid, ReportedUid) ->
    ha_events:log_event(?USER_REPORT_NS, #{
        report_type => user,
        reporting_uid => ReportingUid,
        reported_uid => ReportedUid,
        content_id => <<"unknown_id">>
    }).

log_post_report(ReportingUid, ReportedUid, ContentId) ->
    %% Store reported posts by user to not send them again.
    %% TODO: Keep track of reverse index so that we can flag content depending on num of reports etc.
    model_feed:mark_reported_posts(ReportingUid, ContentId),
    ha_events:log_event(?USER_REPORT_NS, #{
        report_type => post,
        reporting_uid => ReportingUid,
        reported_uid => ReportedUid,
        content_id => ContentId
    }).

log_unknown_report(ReportingUid, ReportedUid, ContentId) ->
    ha_events:log_event(?USER_REPORT_NS, #{
        report_type => unknown,
        reporting_uid => ReportingUid,
        reported_uid => ReportedUid,
        content_id => ContentId
    }).

