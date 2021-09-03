%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, HalloApp, Inc
%%% @doc
%%% SMS module with helper functions to send SMS messages.
%%% @end
%%%-------------------------------------------------------------------
-module(clickatell).
-behavior(mod_sms).
-author(vipin).
-include("logger.hrl").
-include("clickatell.hrl").
-include("ha_types.hrl").
-include("sms.hrl").


%% API
-export([
    init/0,
    can_send_sms/1,
    can_send_voice_call/1,
    send_sms/4,
    send_voice_call/4,
    send_feedback/2,
    compose_body/2     %% for debugging
]).

init() ->
    FromPhoneList = ["12026842029"],
    util_sms:init_helper(clickatell_options, FromPhoneList).

-spec can_send_sms(CC :: binary()) -> boolean().
can_send_sms(_CC) ->
    % TODO: This gateway is disabled for now. We will enable it slowly
    false.
-spec can_send_voice_call(CC :: binary()) -> boolean().
can_send_voice_call(_CC) ->
    % TODO: Voice calls are not implemented yet.
    false.

-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(), UserAgent :: binary()) ->
        {ok, gateway_response()} | {error, sms_fail, retry | no_retry}.
send_sms(Phone, Code, LangId, UserAgent) ->
    {SmsMsgBin, _TranslatedLangId} = mod_translate:translate(<<"server.sms.verification">>, LangId),
    AppHash = util_ua:get_app_hash(UserAgent),
    Msg = io_lib:format("~s: ~s~n~n~n~s", [SmsMsgBin, Code, AppHash]),

    ?INFO("Phone: ~p, Msg: ~p", [Phone, Msg]),
    URL = ?BASE_SMS_URL,
    Headers = [{"X-Version", "1"}, {"Authorization", "bearer " ++ get_auth_token()}],
    Type = "application/json",
    Body = compose_body(Phone, Msg),
    ?DEBUG("Body: ~p", [Body]),
    HTTPOptions = [],
    Options = [],
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    case Response of
        {ok, {{_, 202, _}, _ResHeaders, ResBody}} ->
            Json = jiffy:decode(ResBody, [return_maps]),
            Data = maps:get(<<"data">>, Json),
            Messages = maps:get(<<"message">>, Data),
            [Message] = Messages,
            Id = maps:get(<<"apiMessageId">>, Message),
            IsAccepted = maps:get(<<"accepted">>, Message),
            Status = normalized_status(IsAccepted),
            {ok, #gateway_response{gateway_id = Id, status = Status, response = ResBody}};
        {ok, {{_, HttpStatus, _}, _ResHeaders, ResBody}}->
            ?ERROR("Sending SMS failed Phone:~p, HTTPCode: ~p, response ~p",
                [Phone, HttpStatus, Response]),
            {error, sms_fail, retry};
        _ ->
            % TODO: In all the gateways we don't retry in this case. But I'm not sure why.
            ?ERROR("Sending SMS failed Phone:~p (no_retry) ~p",
                [Phone, Response]),
            {error, sms_fail, no_retry}
    end.

% TODO: Does not support voice calls yet
send_voice_call(_Phone, _Code, _LangId, _UserAgent) ->
    {error, voice_call_fail, retry}.

-spec normalized_status(IsAccepted :: boolean()) -> atom().
normalized_status(true) ->
    accepted;
normalized_status(_) ->
    unknown.

-spec get_auth_token() -> string().
get_auth_token() ->
    get_secret(<<"Clickatell">>, <<"auth_token">>).

-spec get_secret(Name :: binary(), Key :: binary()) -> string().
get_secret(Name, Key) ->
    Json = jiffy:decode(binary_to_list(mod_aws:get_secret(Name)), [return_maps]),
    binary_to_list(maps:get(Key, Json)).

-spec compose_body(Phone, Message) -> Body when
    Phone :: phone(),
    Message :: string(),
    Body :: string().
compose_body(Phone, Message) ->
   Mp = #{<<"to">> => [Phone],
          <<"from">> => util:to_binary(get_originator()),
          <<"text">> => util:to_binary(Message),
          <<"mo">> => <<"1">>},
    jiffy:encode(Mp).

-spec get_originator() -> string().
get_originator() ->
    get_from_phone().

get_from_phone() ->
    util_sms:lookup_from_phone(clickatell_options).

% TODO: Implement if sending feedback back to gateway
-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(_Phone, _AllVerifyInfo) ->
    ok. 

