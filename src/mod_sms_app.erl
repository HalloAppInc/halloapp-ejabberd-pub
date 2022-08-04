%%%----------------------------------------------------------------------
%%% File    : mod_sms_app.erl
%%%
%%% Copyright (C) 2021 halloappinc.
%%%
%%% This module implements an API to interact with phones that make up 
%%% the sms_app gateway. It involves sending messages to request otps
%%% and wake up disconnected devices.
%%%----------------------------------------------------------------------

-module(mod_sms_app).
-author("luke").
-behavior(mod_sms).
-behavior(gen_mod).
-behavior(gen_server).

-include("logger.hrl").
-include("sms_app.hrl").
-include("ha_types.hrl").
-include("sms.hrl").
-include("push_message.hrl").
-include("packets.hrl").
-include("proc.hrl").
-include("ejabberd_sm.hrl").
-define(MAX_RETRY_COUNT, 3).

%% API
-export([
    is_sms_app/1,
    is_sms_app_uid/1,
    wake_up_device/1,
    %% hooks
    user_ping_timeout/1
]).

%% mod_sms callbacks
-export([init/0, can_send_sms/1, send_sms/4, can_send_voice_call/1, send_voice_call/4, send_feedback/2]).
%% gen_mod callbacks
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
%% gen_server callbacks
-export([init/1, terminate/2, handle_call/3, handle_cast/2, handle_info/2, code_change/3]).


-record (otp_info, {
    to_phone :: phone(),
    code :: binary(),
    used_phones :: list(phone()), % tracks sms_app devices that have already been tried for this otp
    from_phone :: undefined | binary(),
    gateway_id  :: undefined | binary(),
    method :: atom(),
    lang_id :: binary(),
    user_agent :: binary()
}).
-type otp_info() :: #otp_info{}.

-record(state, {
    %% phone_usage is intended to track how many times we use each device.
    %% it allows for the selection of local phones to be slightly more even,
    %% instead of just picking the first one every time
    phone_usage :: #{phone() => integer()}
}).
-type state() :: #state{}.

%%====================================================================
%% API
%%====================================================================

-spec is_sms_app(Phone :: phone()) -> boolean().
is_sms_app(Phone) ->
    lists:member(Phone, ?SMS_APP_PHONE_LIST).


-spec is_sms_app_uid(Uid :: uid()) -> boolean().
is_sms_app_uid(Uid) -> 
    case model_accounts:get_phone(Uid) of
        {ok, Phone} -> is_sms_app(Phone);
        {error, missing} ->
            ?ERROR("Invalid Uid: ~p, missing phone", [Uid]),
            false
    end.


-spec wake_up_device(Uid :: uid()) -> ok.
wake_up_device(Uid) ->
    gen_server:cast(?PROC(), {wake_up, Uid}),
    ok.


%%====================================================================
%% mod_sms callbacks
%%====================================================================

init() ->
    util_sms:init_helper(?SMS_APP_OPTIONS, ?SMS_APP_PHONE_LIST),
    ok.


-spec can_send_sms(CC :: binary()) -> boolean().
can_send_sms(_CC) ->
    false.

-spec can_send_voice_call(CC :: binary()) -> boolean().
can_send_voice_call(_CC) ->
    false.


%% wrapper that makes call to gen_server send_sms
-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, sms_fail, retry | no_retry}.
send_sms(Phone, Code, LangId, UserAgent) ->
    OtpInfo = #otp_info{
        to_phone = Phone,
        code = Code,
        lang_id = LangId,
        user_agent = UserAgent,
        method = sms,
        used_phones = [],
        from_phone = undefined,
        gateway_id = undefined
    },
    % use call here because we want to return a value to mod_sms
    gen_server:call(?PROC(), {send_sms, OtpInfo}).


-spec send_voice_call(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, voice_call_fail, retry | no_retry}.
send_voice_call(_Phone, _Code, _LangId, _UserAgent) ->
    %voice calls (if doable) will be implemented almost identically to sms
    {error, sms_fail, no_retry}.


-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(_Phone, _AllVerifyInfo) ->
    ok.


%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(Host, Opts) ->
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()).


stop(_Host) ->
    gen_mod:stop_child(?PROC()).


reload(Host, NewOpts, OldOpts) ->
    gen_server:cast(?PROC(), {reload, Host, NewOpts, OldOpts}).


depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].

%%====================================================================
%% gen_server callbacks
%%====================================================================

init([Host|_]) ->
    PhoneUsageMap = lists:foldl(
        fun(Phone, AccMap) ->
            AccMap#{Phone => 0}
        end, #{}, ?SMS_APP_PHONE_LIST),
    ejabberd_hooks:add(user_ping_timeout, Host, ?MODULE, user_ping_timeout, 100),
    {ok, #state{phone_usage = PhoneUsageMap}}.


terminate(_Reason, _State) ->
    Host = util:get_host(),
    ejabberd_hooks:delete(user_ping_timeout, Host, ?MODULE, user_ping_timeout, 100).


handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

%% send sms callback
handle_call({send_sms, OtpInfo}, _From, State) ->
    #{to_phone := _Phone, code := _Code, lang_id := _LangId, user_agent := _UserAgent,
        method := _Method, used_phones := _UsedPhones} = OtpInfo,
    case send_sms_internal(OtpInfo, State) of
        {error, Reason, NewState} ->
            {reply, {error, Reason, retry}, NewState};
        {ok, Response, NewState} ->
            {reply, {ok, Response}, NewState}
    end;

handle_call(Request, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Request]),
    {noreply, State}.


handle_cast({wake_up, Uid}, State) ->
    case is_sms_app_uid(Uid) of
        true ->
            MsgId = util_id:new_msg_id(),
            Msg = #pb_msg{
                id = MsgId,
                to_uid = Uid,
                payload = #pb_wake_up{}
            },
            ?INFO("sending message to wake_up, Uid: ~p, MsgId: ~p", [Uid, MsgId]),
            ejabberd_router:route(Msg);
        false -> ok
    end,
    {noreply, State};
handle_cast({send_sms, OtpInfo}, State) ->
    case send_sms_internal(OtpInfo, State) of
        {error, _Reason, NewState} ->
            {noreply, NewState};
        {ok, _Response, NewState} ->
            {noreply, NewState}
    end;
handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};
handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


%% handler for reply from sms_app client
handle_info({iq_reply, #pb_iq{payload = #pb_client_otp_response{} = ClientOtpResponse } = IQ,
        OtpInfo}, State) ->
    %% this handler is called with the response from the first otp request attempt.
    %% regardless of the reponse, we want to log it in redis. This method serves
    %% the same purpose as the callbacks in mod_sms_callback.erl.
    ?INFO("sms_app otp_response: ~p, OtpInfo: ~p", [IQ, OtpInfo]),
    %% additionally, if we get a failure response, we want to re-try with a new
    %% phone by just casting to send_sms again with the recieved OtpInfo (which
    %% stores all the previously used phones)
    %% TODO: add retries here.
    Status = case ClientOtpResponse#pb_client_otp_response.result of
        success -> sent;
        failure ->
            ?ERROR("Failed sending sms_app, otp_response: ~p, otp_info: ~p", [ClientOtpResponse, OtpInfo]),
            failed;
        _ -> unknown
    end,
    GatewayId = OtpInfo#otp_info.gateway_id,
    GatewayResponse = #gateway_response{gateway_id = GatewayId, gateway = ?MODULE, status = Status},
    ok = mod_sms_callback:add_gateway_callback_info(GatewayResponse),
    {noreply, State};

%% handler for when the device doesn't respond to a ping w/in 5s.
handle_info({iq_reply, timeout, OtpInfo}, State) ->
    ?INFO("send_sms_timeout OtpInfo: ~p", [OtpInfo]),
    %% here, we want to re-try with a new phone by just casting send_sms
    %% again with the recieved OtpInfo (which stores all the previously used
    %% phones). Basically the same as recieving a failure response, but don't
    %% store anything in redis.
    RetryCount = length(OtpInfo#otp_info.used_phones),
    case RetryCount > ?MAX_RETRY_COUNT of
        true ->
            %% TODO: We need to retry it using some other gateway here..
            ?ERROR("Failed sending_sms with max_retries, OtpInfo: ~p", [OtpInfo]),
            ok;
        false ->
            ?INFO("Retrying sending otp with sms_app, retry_count: ~p, Phone: ~p", [RetryCount, OtpInfo]),
            gen_server:cast(?PROC(), {send_sms, OtpInfo})
    end,
    {noreply, State};

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%====================================================================
%% Hook callbacks
%%====================================================================

-spec user_ping_timeout(SessionInfo :: #session_info{}) -> ok.
user_ping_timeout(#session_info{uid = Uid} = _SessionInfo) ->
    wake_up_device(Uid).


%%====================================================================
%% Internal Functions
%%====================================================================

-spec send_sms_internal(OtpInfo :: otp_info(), State :: state()) -> {error, atom(), state()} | {ok, gateway_response(), state()}.
send_sms_internal(OtpInfo, State) ->
    LangId = OtpInfo#otp_info.lang_id,
    Code = OtpInfo#otp_info.code,
    Phone = OtpInfo#otp_info.to_phone,
    UserAgent = OtpInfo#otp_info.user_agent,
    Method = OtpInfo#otp_info.method,
    UsedPhones = OtpInfo#otp_info.used_phones,
    {Msg, _TranslatedLangId} = util_sms:get_sms_message(UserAgent, Code, LangId),
    case pick_from_phone(UsedPhones, ?SMS_APP_PHONE_LIST) of
        {error, Reason} ->
            ?ERROR("sms_app clients unavailable, reason: ~p, OtpInfo: ~p", [Reason, OtpInfo]),
            {error, Reason, State};
        {ok, FromPhone} ->
            CurrentPhoneUsageMap = State#state.phone_usage,
            NumTriesFromPhone = maps:get(FromPhone, CurrentPhoneUsageMap, 0),
            FromUid = model_phone:get_uid(FromPhone),
            UUID = util_id:new_long_id(),
            GatewayId = <<FromPhone/binary, "/", UUID/binary>>,

            OtpRequestPayload = #pb_client_otp_request{
                method = Method,
                phone = Phone,
                content = Msg
            },
            NewOtpInfo = OtpInfo#{
                used_phones => [FromPhone | UsedPhones],
                from_phone => FromPhone,
                gateway_id => GatewayId
            },
            IQ = #pb_iq{
                to_uid = FromUid,
                type = set,
                payload = OtpRequestPayload
            },
            ?INFO("send_otp through Phone: ~p, OtpInfo: ~p", [FromPhone, NewOtpInfo]),
            ejabberd_iq:route(IQ, ?PROC(), NewOtpInfo, ?SMS_APP_REQUEST_TIMEOUT),

            Response = #gateway_response{
                % gateway_id notes which phone but is also unique
                gateway_id = GatewayId,
                status = <<"requested">>,
                response = undefined
            },
            NewPhoneUsageMap = CurrentPhoneUsageMap#{FromPhone => NumTriesFromPhone + 1},
            NewState = State#state{phone_usage = NewPhoneUsageMap},
            {ok, Response, NewState}
    end.


-spec pick_from_phone(UsedPhones :: [binary()], AllPhones :: [binary()]) -> {ok, phone()} | {error, any()}.
pick_from_phone(UsedPhones, AllPhones) ->
    TryPhones = lists:filter(
        fun(Phone) ->
            not lists:member(Phone, UsedPhones)
        end, AllPhones),
    OnlinePhones = lists:filter(
        fun(Phone) ->
            {ok, Uid} = model_phone:get_uid(Phone),
            case Uid of
                undefined -> false;
                _ ->
                    %% Make sure uid is online
                    ejabberd_sm:is_user_online(Uid)
            end
        end, TryPhones),
    case OnlinePhones of
        [_H | _] ->
            WhichIdx = rand:uniform(length(OnlinePhones)),
            {ok, lists:nth(WhichIdx, OnlinePhones)};
        [] -> {error, no_device_available}
    end.

