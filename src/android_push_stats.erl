%%%-------------------------------------------------------------------------------------------
%%% File    : android_push_stats.erl
%%%
%%% Copyright (C) 2022 HalloApp inc.
%%%
%%% Sends query to google about fcm push stats
%%%-------------------------------------------------------------------------------------------

-module(android_push_stats).

-include("logger.hrl").
-include("proc.hrl").
-include("time.hrl").
-include("push_message.hrl").

%% TODO: Should move away from having the key in the codebase.
%% Unfortunately one of the dependencies needs it in a file as of now. we can fix it eventually.
-define(GOOGLE_SERVICE_KEY_FILE, "google_service_key.json").
-define(FCM_URL_PREFIX, <<"https://fcmdata.googleapis.com/v1beta1/projects/">>).
-define(FCM_URL_SUFFIX, <<"/androidApps/1:817105367342:android:2c61d3d6317db7a16e4abf/deliveryData">>).
-define(SCOPE_URL, <<"https://www.googleapis.com/auth/cloud-platform">>).

-export([
    fetch_push_stats/0
]).


fetch_push_stats() ->
    ServiceKeyFilePath = filename:join(misc:data_dir(), ?GOOGLE_SERVICE_KEY_FILE),
    {ok, SecretBin} = file:read_file(ServiceKeyFilePath),
    #{project_id := ProjectId} = jsx:decode(SecretBin, [return_maps, {labels, atom}]),
    {ok, #{access_token := AccessToken}} = google_oauth:get_access_token(ServiceKeyFilePath, ?SCOPE_URL),
    AuthToken = util:to_list(<<"Bearer ", AccessToken/binary>>),
    ?DEBUG("AuthToken: ~p, ~p", [AccessToken, AuthToken]),
    FcmUrl = util:to_list(<<?FCM_URL_PREFIX/binary, ProjectId/binary, ?FCM_URL_SUFFIX/binary>>),
    Request = {FcmUrl, [{"Authorization", AuthToken}]},
    Response = httpc:request(get, Request, [], []),

    ?INFO("fetch_push_stats result: ~p", [Response]),

    case Response of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            TsMs = util:now_ms(),
            Date = util:tsms_to_date(TsMs), 
            ha_events:write_log(<<"server.android_push_stats_dump">>, Date, list_to_binary(Body));
        _ -> 
            ?INFO("fetch_push_stats had error: see response", [])
    end.

