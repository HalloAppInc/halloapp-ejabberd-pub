%%%----------------------------------------------------------------------
%%% File    : mod_ka_vanity.erl
%%%
%%% Copyright (C) 2023 HalloApp Inc.
%%%----------------------------------------------------------------------

-module(mod_ka_vanity).
-author('vipin').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").

%% gen_mod callbacks.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% hooks and api.
-export([
    process_local_iq/1,
    report_metrics/2,
    report_metrics/3
]).


%%====================================================================
%% gen_mod api
%%====================================================================

start(_Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_post_metrics_request, ?MODULE, process_local_iq),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_post_metrics_request),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% iq handlers and api
%%====================================================================

process_local_iq(
    #pb_iq{from_uid = _Uid, type = get, payload = #pb_post_metrics_request{
        post_id = PostId}} = IQ) ->
    {ok, NumImpressions} = model_feed:get_post_num_seen(PostId),
    pb:make_iq_result(IQ, #pb_post_metrics_result{result = ok, post_metrics = #pb_post_metrics{
        num_impressions = NumImpressions}}).

report_metrics(Uid, Type) ->
    AppType = util_uid:get_app_type(Uid),
    case AppType of
        katchup -> report_metrics_internal(Uid, Type);
        _ -> ok
    end.

report_metrics(Uid, PostId, seen) ->
    AppType = util_uid:get_app_type(Uid),
    case AppType of
        katchup -> report_metrics_internal(Uid, PostId, seen);
        _ -> ok
    end.

report_metrics_internal(Uid, post) ->
    model_accounts:inc_num_posts(Uid);

report_metrics_internal(Uid, comment) ->
    model_accounts:inc_num_comments(Uid).

report_metrics_internal(Uid, PostId, seen) ->
    model_accounts:inc_num_seen(Uid),
    model_feed:inc_post_num_seen(PostId).

