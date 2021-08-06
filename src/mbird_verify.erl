%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, HalloApp, Inc
%%% @doc
%%% @end
%%%-------------------------------------------------------------------
-module(mbird_verify).
-behavior(mod_sms).
-author("michelle").
-include("logger.hrl").
-include("mbird_verify.hrl").
-include("ha_types.hrl").
-include("sms.hrl").
-include("time.hrl").


%% API
-export([
    send_sms/4,
    send_voice_call/4,
    send_feedback/2,
    verify_code_internal/3,
    verify_code/3
]).


-spec send_sms(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, sms_fail}.
send_sms(Phone, _Code, _LangId, _UserAgent) ->
    sending_helper(Phone, "sms").


-spec send_voice_call(Phone :: phone(), Code :: binary(), LangId :: binary(),
        UserAgent :: binary()) -> {ok, gateway_response()} | {error, tts_fail}.
send_voice_call(Phone, _Code, _LangId, _UserAgent) -> 
    sending_helper(Phone, "tts").


-spec sending_helper(Phone :: phone(), Method :: string())
        -> {ok, gateway_response()} | {error, sms_fail} | {error, tts_fail}.
sending_helper(Phone, Method) ->
    URL = ?BASE_URL,
    Type = "application/x-www-form-urlencoded",
    [Headers, Type, HTTPOptions, Options] = fetch_headers(Phone),
    Body = compose_body(Phone, Method),
    ?DEBUG("Body: ~p", [Body]),
    Response = httpc:request(post, {URL, Headers, Type, Body}, HTTPOptions, Options),
    ?DEBUG("Response: ~p", [Response]),
    case Response of
        {ok, {{_, 201, _}, _ResHeaders, ResBody}} ->
            Json = jiffy:decode(ResBody, [return_maps]),
            Id = maps:get(<<"id">>, Json),  
            Status = normalized_status(maps:get(<<"status">>, Json)),
            ?INFO("Id: ~p Status: ~p Response ~p", [Id, Status, ResBody]),
            {ok, #gateway_response{gateway_id = Id, status = Status, response = ResBody}};
        _ ->
            ?ERROR("Sending ~p to ~p failed: ~p", [Method, Phone, Response]),
            {error, list_to_atom(re:replace(string:lowercase(Method), " ", "_", [{return, list}]) ++ "_fail")}
    end.


-spec verify_code(Phone :: phone(), Code :: binary(), AllVerifyInfo :: [verification_info()])
        -> {match, verification_info()} | nomatch.
verify_code(Phone, Code, AllVerifyInfo) ->
    case lists:search(
        fun(Info) -> 
            #verification_info{gateway = Gateway, status = Status, sid = Sid} = Info,
            Gateway =:= <<"mbird_verify">> andalso Status =:= <<"sent">> andalso
            % Run network calls on mbird_verify attempts until first match & update code
            % Must be called with header mbird_verify: to allow for mecking in unit test
            mbird_verify:verify_code_internal(Phone, Code, Sid)
        end, AllVerifyInfo) of
            false ->
                nomatch;
            {value, Match} ->
                ok = model_phone:update_sms_code(Phone, Code, Match#verification_info.attempt_id),
                {match, Match}
    end.


-spec verify_code_internal(Phone :: phone(), Code :: binary(), Sid :: binary()) -> boolean().
verify_code_internal(Phone, Code, Sid) ->
    [Headers, _Type, HTTPOptions, Options] = fetch_headers(Phone),
    URL = ?VERIFY_URL(Sid, Code),
    ?INFO("Phone:~p URL: ~p Headers:~p", [URL, Headers]),
    Response = httpc:request(get, {URL, Headers}, HTTPOptions, Options),
    ?INFO("Response: ~p", [Response]),
    case Response of        
        {ok, {{_, 200, _}, _ResHeaders, _ResBody}} ->
            GatewayResponse = #gateway_response{gateway_id = Sid, gateway = mbird_verify, status = accepted},
            ok = model_phone:add_gateway_callback_info(GatewayResponse),
            true;
        % Invalid codes return a 422 Resource Not Created Error
        {ok, {{_, 422, _}, _ResHeaders, _ResBody}} ->
            GatewayResponse = #gateway_response{gateway_id = Sid, gateway = mbird_verify, status = delivered},
            ok = model_phone:add_gateway_callback_info(GatewayResponse),
            false;
        _ ->
            ?ERROR("Phone: ~p , Failed validation: ~p", [Phone, Response]),
            false
    end.


-spec fetch_headers(Phone :: phone()) -> list().
fetch_headers(Phone) ->
    Headers = [{"Authorization", "AccessKey " ++ get_access_key(util:is_test_number(Phone))}],
    Type = "application/x-www-form-urlencoded",
    [Headers, Type, [], []].


-spec compose_body(Phone :: phone(), Method :: string()) -> uri_string:uri_string().
compose_body(Phone,  Method) ->
    PlusPhone = "+" ++ binary_to_list(Phone),
    uri_string:compose_query([
        {"recipient", PlusPhone},
        {"type", Method},
        {"timeout", util:to_binary(?DAYS)}
    ], [{encoding, latin1}]).


% verified - correct code was entered
% sent - code has yet to be verified yet but message was sent
% expired - no attempt to verify code within the set time (currently 24hrs)
% failed - wrong code was entered
-spec normalized_status(Status :: binary()) -> atom().
normalized_status(<<"verified">>) ->
    accepted;
normalized_status(<<"sent">>) ->
    sent;
normalized_status(<<"expired">>) ->
    delivered;
normalized_status(<<"failed">>) ->
    delivered;
normalized_status(_) ->
    unknown.


-spec get_access_key(IsTest :: boolean()) -> string().
get_access_key(true) ->
    Json = jiffy:decode(binary_to_list(mod_aws:get_secret(<<"MBirdTest">>)), [return_maps]),
    binary_to_list(maps:get(<<"access_key">>, Json));
get_access_key(false) ->
    Json = jiffy:decode(binary_to_list(mod_aws:get_secret(<<"MBird">>)), [return_maps]),
    binary_to_list(maps:get(<<"access_key">>, Json)).


% Todo: Implement if sending feedback back to mbird_verify
-spec send_feedback(Phone :: phone(), AllVerifyInfo :: list()) -> ok.
send_feedback(_Phone, _AllVerifyInfo) ->
    ok. 

