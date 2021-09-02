%%%----------------------------------------------------------------------
%%% File    : sms_app.erl
%%%
%%% Copyright (C) 2021 halloappinc.
%%%
%%% This module implements an API to interact with phones that make up 
%%% the sms_app gateway. It involves sending messages to request otps
%%% and wake up disconnected devices.
%%%----------------------------------------------------------------------

-module(sms_app).
-author("luke").
-behavior(mod_sms).
-include("logger.hrl").
-include("sms_app.hrl").
-include("ha_types.hrl").
-include("sms.hrl").
-include("push_message.hrl").
-include("ejabberd_sm.hrl").

-export([
    init/1,
    stop/1,
    can_send_sms/1,
    send_sms/4,
    can_send_voice_call/1,
    send_voice_call/4,
    send_feedback/2,
    is_sms_app/1,
    is_sms_app_uid/1,
    wake_up_device/1,
    user_ping_timeout/1
]).


init(Host) ->
    ejabberd_hooks:add(user_ping_timeout, Host, ?MODULE, user_ping_timeout, 100),
    ok.

stop(Host) ->
    ejabberd_hooks:delete(user_ping_timeout, Host, ?MODULE, user_ping_timeout, 100),
    ok.

-spec is_sms_app(Phone :: phone()) -> boolean().
is_sms_app(Phone) ->
    lists:member(Phone, ?SMS_APP_PHONE_LIST).


-spec is_sms_app_uid(Uid :: uid()) -> boolean().
is_sms_app_uid(Uid) -> 
    {ok, Phone} = model_accounts:get_phone(Uid),
    is_sms_app(Phone).


-spec can_send_sms(CC :: binary()) -> boolean().
can_send_sms(_CC) ->
    false.
-spec can_send_voice_call(CC :: binary()) -> boolean().
can_send_voice_call(_CC) ->
    false.


-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, sms_fail, retry | no_retry}.
send_sms(_Phone, _Code, _LangId, _UserAgent) ->
    {error, sms_fail, no_retry}.


-spec send_voice_call(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, voice_call_fail, retry | no_retry}.
send_voice_call(_Phone, _Code, _LangId, _UserAgent) ->
    {error, sms_fail, no_retry}.


-spec wake_up_device(User :: uid()) -> ok.
wake_up_device(User) ->
    case is_sms_app_uid(User) of
        true -> 
            MsgId = util_id:new_msg_id(),
            Msg = #pb_msg{
                id = MsgId, 
                to_uid = User,
                payload = #pb_wake_up{}
            }, 
            ejabberd_router:route(Msg);
        false -> ok
    end,
    ok.


-spec user_ping_timeout(SessionInfo :: #session_info{}) -> ok.
user_ping_timeout(#session_info{uid = User} = _SessionInfo) ->
    wake_up_device(User).


-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(_Phone, _AllVerifyInfo) ->
    ok. 

