%%%-------------------------------------------------------------------------------------------
%%% File    : mod_android_push_msg.erl
%%%
%%% Copyright (C) 2022 HalloApp inc.
%%%
%%% Supplement to mod_android_push. Helps send a push notification
%%%-------------------------------------------------------------------------------------------

-module(mod_android_push_msg).

-include("logger.hrl").
-include("push_message.hrl").

%% TODO(murali@): convert everything to 1 timeunit.
-define(HTTP_TIMEOUT_MILLISEC, 10000).             %% 10 seconds.
-define(HTTP_CONNECT_TIMEOUT_MILLISEC, 10000).     %% 10 seconds.

-define(FCM_GATEWAY, "https://fcm.googleapis.com/fcm/send").

-export([push_message_item/3]).

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%%====================================================================
%% gen_mod API.
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start ~w", [?MODULE]),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].


%%====================================================================
%% internal module functions
%%====================================================================

-spec push_message_item(PushMessageItem :: push_message_item(), State :: push_state(), ParentPid :: pid()) -> push_state().
push_message_item(PushMessageItem, #push_state{pendingMap = PendingMap} = State, ParentPid) ->
    PushMetadata = push_util:parse_metadata(PushMessageItem#push_message_item.message),
    Id = PushMessageItem#push_message_item.id,
    Uid = PushMessageItem#push_message_item.uid,
    ContentId = PushMetadata#push_metadata.content_id,
    ContentType = PushMetadata#push_metadata.content_type,
    Token = PushMessageItem#push_message_item.push_info#push_info.token,
    Version = PushMessageItem#push_message_item.push_info#push_info.client_version,
    HTTPOptions = [
            {timeout, ?HTTP_TIMEOUT_MILLISEC},
            {connect_timeout, ?HTTP_CONNECT_TIMEOUT_MILLISEC}
    ],
    Options = [{sync, false}, {receiver, ParentPid}],
    FcmApiKey = get_fcm_apikey(),

    ContentMap = case PushMetadata#push_metadata.push_type of
        direct_alert ->
            % Used only in marketing alerts
            {Title, Body} = push_util:get_title_body(PushMessageItem#push_message_item.message,
                                                    PushMessageItem#push_message_item.push_info),
            DataMap = #{
                <<"title">> => Title,
                <<"body">> => Body
            },
            ChannelId = case util_ua:is_version_greater_than(Version, <<"HalloApp/Android0.216">>) of
                true -> <<"broadcast_notifications">>;
                false -> <<"critical_notifications">>
            end,
            DirectAlertMap = DataMap#{
                <<"sound">> => <<"default">>,
                <<"icon">> => <<"ic_notification">>,
                <<"android_channel_id">> => ChannelId,
                <<"color">> => <<"#ff4500">>
            },
            #{ <<"notification">> => DirectAlertMap };
        _ ->
            % Dont send any payload to android in the push channel.
            #{ <<"data">> => #{} }
    end,
    PushMessage = ContentMap#{<<"to">> => Token, <<"priority">> => <<"high">>},
    Request = {?FCM_GATEWAY, [{"Authorization", "key=" ++ FcmApiKey}],
            "application/json", jiffy:encode(PushMessage)},
    case httpc:request(post, Request, HTTPOptions, Options) of
        {ok, RequestId} ->
            ?INFO("Uid: ~s, MsgId: ~s, ContentId: ~s, ContentType: ~s, RequestId: ~p",
                [Uid, Id, ContentId, ContentType, RequestId]),
            NewPendingMap = PendingMap#{RequestId => PushMessageItem},
            State#push_state{pendingMap = NewPendingMap};
        {error, Reason} ->
            ?ERROR("Push failed, Uid:~s, token: ~p, reason: ~p",
                    [Uid, binary:part(Token, 0, 10), Reason]),
            retry_message_item(PushMessageItem, ParentPid),
            State
    end.


-spec retry_message_item(PushMessageItem :: push_message_item(), ParentPid :: pid()) -> reference().
retry_message_item(PushMessageItem, ParentPid) ->
    RetryTime = PushMessageItem#push_message_item.retry_ms,
    setup_timer({retry, PushMessageItem}, ParentPid, RetryTime).


-spec setup_timer(Msg :: any(), ParentPid :: pid(), Timeout :: integer()) -> reference().
setup_timer(Msg, ParentPid, Timeout) ->
    NewTimer = erlang:send_after(Timeout, ParentPid, Msg),
    NewTimer.


-spec get_fcm_apikey() -> string().
get_fcm_apikey() ->
    mod_aws:get_secret_value(<<"fcm">>, <<"apikey">>).

