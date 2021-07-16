%%%----------------------------------------------------------------------
%%% File    : twilio_verify.erl
%%%
%%% Copyright (C) 2021 halloappinc.
%%%
%%% This module implements API needed to interface with Twilio Verify
%%%----------------------------------------------------------------------

-module(twilio_verify).
-behavior(mod_sms).
-author('michelle').
-include("logger.hrl").
-include("twilio_verify.hrl").
-include("ha_types.hrl").
-include("sms.hrl").

-export([
    send_sms/4,
    send_voice_call/4,
    send_feedback/2,
    get_latest_verify_info/1   %% Need for test.
]).

-define(TTL_SMS_SID, 600).


-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, sms_fail}.
send_sms(Phone, Code, _LangId, _UserAgent) ->
    send_verification(Phone, Code, "sms").


-spec send_voice_call(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, call_fail}.
send_voice_call(Phone, Code, _LangId, _UserAgent) -> 
    send_verification(Phone, Code, "call").


-spec send_verification(Phone :: phone(), Code :: binary(), Method :: string())
     -> {ok, gateway_response()} | {error, sms_fail} | {error, call_fail}.
send_verification(Phone, Code, Method) ->
    URL = ?VERIFICATION_URL,
    [Headers, Type, HTTPOptions, Options] = fetch_headers(),
    Body = compose_send_body(Phone, Code, Method),
    ?DEBUG("Body: ~p", [Body]),
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    case Response of
        {ok, {{_, 201, _}, _ResHeaders, ResBody}} ->
            Json = jiffy:decode(ResBody, [return_maps]),
            Id = maps:get(<<"sid">>, Json),  
            Status = normalized_status(maps:get(<<"status">>, Json)),
            {ok, #gateway_response{gateway_id = Id, status = Status, response = ResBody}};
        _ ->
            ?ERROR("Sending ~p to ~p failed: ~p", [Method, Phone, Response]),
            {error, list_to_atom(re:replace(string:lowercase(Method), " ", "_", [{return, list}]) ++ "_fail")}
    end.


-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(Phone, AllVerifyInfo) ->
    case get_latest_verify_info(AllVerifyInfo) of
        [] -> ok;
        [AttemptId, Sid] ->
            URL = ?VERIFICATION_URL ++ binary_to_list(Sid),
            [Headers, Type, HTTPOptions, Options] = fetch_headers(),
            Body = compose_feedback_body(),
            ?DEBUG("Body: ~p", [Body]),
            Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
            ?DEBUG("Response: ~p", [Response]),
            case Response of
                {ok, {{_, 200, _}, _ResHeaders, ResBody}} ->
                    Json = jiffy:decode(ResBody, [return_maps]),
                    Id = maps:get(<<"sid">>, Json),
                    Price = maps:get(<<"amount">>, Json),
                    RealPrice = case try string:to_float(binary_to_list(Price))
                    catch _:_ -> {error, no_float}
                    end of
                        {error, _} -> undefined;
                        {XX, []} -> abs(XX)
                    end,
                    GatewayResponse = #gateway_response{gateway_id = Id, gateway = twilio_verify,
                        status = accepted, price = RealPrice},
                    ok = model_phone:add_gateway_callback_info(GatewayResponse);
                _ ->
                    ?ERROR("Feedback info failed, Phone:~p AttemptId: ~p Response: ~p", [Phone, AttemptId, Response])
            end
    end.


-spec fetch_headers() -> list().
fetch_headers() ->
    Headers = fetch_auth_headers(),
    Type = "application/x-www-form-urlencoded",
    [Headers, Type, [], []].


-spec compose_send_body(Phone :: phone(), Code :: binary(), Method :: string()) -> uri_string:uri_string().
compose_send_body(Phone, Code, Method) ->
    PlusPhone = "+" ++ binary_to_list(Phone),
    uri_string:compose_query([
        {"To", PlusPhone },
        {"Channel", Method},
        {"CustomCode", Code}
    ], [{encoding, utf8}]).


-spec compose_feedback_body() -> uri_string:uri_string().
compose_feedback_body() ->
    uri_string:compose_query([
        {"Status", <<"approved">>}
    ], [{encoding, utf8}]).


-spec fetch_tokens() -> {string(), string()}.
fetch_tokens() ->
    Json = jiffy:decode(binary_to_list(mod_aws:get_secret(<<"Twilio">>)), [return_maps]),
    {binary_to_list(maps:get(<<"account_sid">>, Json)),
     binary_to_list(maps:get(<<"auth_token">>, Json))}.


-spec fetch_auth_headers() -> string().
fetch_auth_headers() ->
    {AccountSid, AuthToken} = fetch_tokens(),
    AuthStr = base64:encode_to_string(AccountSid ++ ":" ++ AuthToken),
    [{"Authorization", "Basic " ++ AuthStr}].


-spec normalized_status(Status :: binary()) -> atom().
normalized_status(<<"approved">>) ->
    accepted;
normalized_status(<<"pending">>) ->
    queued;
normalized_status(<<"canceled">>) ->
    failed;
normalized_status(_) ->
    unknown.


-spec get_latest_verify_info(AllVerifyInfoList :: list()) -> list().
get_latest_verify_info(AllVerifyInfoList) ->
    TwilioVerifyList = lists:dropwhile(
        fun(Info) ->
            Info#verification_info.gateway =/= <<"twilio_verify">>
        end, lists:reverse(AllVerifyInfoList)),
    Deadline = util:now() - ?TTL_SMS_SID,
    case TwilioVerifyList of
        [] -> [];
        _ ->
            [Latest | _Rest] = TwilioVerifyList,
            #verification_info{attempt_id = AttemptId, sid = Sid, ts = Timestamp} = Latest,
            case Deadline < Timestamp of
                true -> [AttemptId, Sid];
                false -> []
            end
    end.

