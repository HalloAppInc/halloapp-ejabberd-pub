%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%% HTTP API module for HalloApp. Here we take HTTP API requests
%%% from the clients and implement APIs like registration and request_sms
%%% @end
%%% Created : 30. Mar 2020 11:42 AM
%%%-------------------------------------------------------------------
-module(mod_halloapp_http_api).
-author("nikola").
-behaviour(gen_mod).

-ifdef(TEST).
-export([
    check_ua/1,
    check_name/1,
    check_invited/4,
    check_sms_code/2,
    is_version_invite_opened/1
]).
-endif.

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").
-include("account.hrl").
-include("ha_types.hrl").
-include("whisper.hrl").
-include("sms.hrl").
-include("time.hrl").
-include("invites.hrl").

-define(MSG_TO_SIGN, <<"HALLO">>).
-define(IP_BACKOFF_THRESHOLD, 5).
-define(BLOCK_IP_BACKOFF_TIME, 12 * ?HOURS).

-define(PHONE_PATTERN_BACKOFF_THRESHOLD, 15).

%% API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([
    process/2,
    process_otp_request/1,
    process_register_request/1,
    insert_blocklist/0,
    insert_blocklist/2,
    check_blocked/4,  %% for testing
    delete_client_ip/1,  %% for testing
    delete_phone_pattern/2  %% for testing
]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------


-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
process([<<"registration">>, <<"request_sms">>],
        #request{method = 'POST', data = Data, ip = {IP, _Port}, headers = Headers}) ->
    ?INFO("Invalid old request_sms request, Data: ~p, Headers: ~p", [Data, Headers]),
    process_otp_request(Data, IP, Headers);

process([<<"registration">>, <<"request_otp">>],
        #request{method = 'POST', data = Data, ip = {IP, _Port}, headers = Headers}) ->
    stat:count("HA/registration", "request_otp_request", 1, [{protocol, "https"}]),
    process_otp_request(Data, IP, Headers);

%% Newer version of `register` API. Uses spub instead of password.
%% TODO(vipin): Refactor error handling code.
process([<<"registration">>, <<"register2">>],
        #request{method = 'POST', data = Data, ip = {IP, _Port}, headers = Headers}) ->
    try
        ClientIP = util_http:get_ip(IP, Headers),
        UserAgent = util_http:get_user_agent(Headers),
        ?INFO("spub registration request: r:~p ip:~s ua:~s", [Data, ClientIP, UserAgent]),
        Payload = jiffy:decode(Data, [return_maps]),
        RawPhone = maps:get(<<"phone">>, Payload),
        Code = maps:get(<<"code">>, Payload),
        Name = maps:get(<<"name">>, Payload),
        SEdPubB64 = maps:get(<<"s_ed_pub">>, Payload),
        SignedPhraseB64 = maps:get(<<"signed_phrase">>, Payload),
        GroupInviteToken = maps:get(<<"group_invite_token">>, Payload, undefined),
        IdentityKeyB64 = maps:get(<<"identity_key">>, Payload),
        SignedKeyB64 = maps:get(<<"signed_key">>, Payload),
        OneTimeKeysB64 = maps:get(<<"one_time_keys">>, Payload),
        RawData = Payload#{headers => Headers, ip => IP},
        stat:count("HA/registration", "verify_otp_request", 1, [{protocol, "https"}]),

        RequestData = #{
            raw_phone => RawPhone, name => Name, ua => UserAgent, code => Code,
            ip => ClientIP, group_invite_token => GroupInviteToken, s_ed_pub => SEdPubB64,
            signed_phrase => SignedPhraseB64, id_key => IdentityKeyB64, sd_key => SignedKeyB64,
            otp_keys => OneTimeKeysB64, push_payload => Payload, raw_data => RawData, protocol => https
        },
        case process_register_request(RequestData) of
            {ok, Result} ->
                stat:count("HA/registration", "verify_otp_success", 1, [{protocol, "https"}]),
                {200, ?HEADER(?CT_JSON), jiffy:encode(Result)};
            {error, internal_server_error} ->
                util_http:return_500();
            {error, bad_user_agent} ->
                util_http:return_400();
            {error, Reason} ->
                util_http:return_400(Reason)
        end
    catch
        error: {badkey, MissingField} when is_binary(MissingField)->
            BadKeyError = util:to_atom(<<"missing_", MissingField/binary>>),
            log_register_error(BadKeyError),
            util_http:return_400(BadKeyError);
        error : Reason2 : Stacktrace  ->
            log_register_error(server_error),
            ?ERROR("register error: ~p, ~p", [Reason2, Stacktrace]),
            util_http:return_500()
    end;

%% Return the group name based on group_invite_token
process([<<"registration">>, <<"get_group_info">>],
        #request{method = 'OPTIONS'}) ->
    {204, ?OPTIONS_HEADER, []};
process([<<"registration">>, <<"get_group_info">>],
        #request{method = 'POST', data = Data, ip = {IP, _Port}, headers = Headers}) ->
    try
        ClientIP = util_http:get_ip(IP, Headers),
        UserAgent = util_http:get_user_agent(Headers),
        ?INFO("get_group_info request: r:~p ip:~s ua:~s", [Data, ClientIP, UserAgent]),
        Payload = jiffy:decode(Data, [return_maps]),
        GroupInviteToken = maps:get(<<"group_invite_token">>, Payload),

        case mod_groups:web_preview_invite_link(GroupInviteToken) of
            {error, invalid_invite} ->
                util_http:return_400(invalid_invite);
            {ok, Name, Avatar} ->
                {200, ?HEADER(?CT_JSON), jiffy:encode(#{
                    result => ok,
                    name => Name,
                    avatar => Avatar
                })}
        end
    catch
        error : invalid_client_version ->
            ?ERROR("get_group_info error: invalid_client_version ~p", [Headers]),
            util_http:return_400(invalid_client_version);
        error: {badkey, MissingField} when is_binary(MissingField)->
            BadKeyError = util:to_atom(<<"missing_", MissingField/binary>>),
            util_http:return_400(BadKeyError);
        error : Reason : Stacktrace  ->
            ?ERROR("get_group_info error: ~p, ~p", [Reason, Stacktrace]),
            util_http:return_500()
    end;

process([<<"_ok">>], _Request) ->
    {200, ?HEADER(?CT_PLAIN), <<"ok">>};
process(Path, Request) ->
    ?INFO("404 Not Found: path: ~p, r:~p", [Path, Request]),
    util_http:return_404().

-spec process_otp_request(Data :: string(), IP :: string(), Headers :: list()) -> http_response().
process_otp_request(Data, IP, Headers) ->
    try
        ?DEBUG("Data:~p", [Data]),
        UserAgent = util_http:get_user_agent(Headers),
        ClientIP = util_http:get_ip(IP, Headers),
        Payload = jiffy:decode(Data, [return_maps]),
        RawPhone = maps:get(<<"phone">>, Payload),
        MethodBin = maps:get(<<"method">>, Payload, <<"sms">>),
        LangId = maps:get(<<"lang_id">>, Payload, <<"en-US">>),
        GroupInviteToken = maps:get(<<"group_invite_token">>, Payload, undefined),
        ?INFO("raw_phone:~p, ua:~p ip:~s method: ~s, langId: ~p, payload:~p ",
            [RawPhone, UserAgent, ClientIP, MethodBin, LangId, Payload]),
        RawData = Payload#{headers => Headers, ip => IP},
        RequestData = #{raw_phone => RawPhone, lang_id => LangId, ua => UserAgent, method => MethodBin,
            ip => ClientIP, group_invite_token => GroupInviteToken, raw_data => RawData, protocol => https
        },
        case process_otp_request(RequestData) of
            {ok, Phone, RetryAfterSecs} ->
                stat:count("HA/registration", "request_otp_success", 1, [{protocol, "https"}]),
                {200, ?HEADER(?CT_JSON),
                    jiffy:encode({[
                        {phone, Phone},
                        {retry_after_secs, RetryAfterSecs},
                        {result, ok}
                    ]})};
            {error, retried_too_soon, Phone, RetryAfterSecs} ->
                return_retried_too_soon(Phone, RetryAfterSecs, MethodBin);
            {error, dropped, Phone, RetryAfterSecs} ->
                return_dropped(Phone, RetryAfterSecs, MethodBin);
            {error, internal_server_error} ->
                util_http:return_500();
            {error, ip_blocked} ->
                util_http:return_400();
            {error, bad_user_agent} ->
                util_http:return_400();
            {error, Reason} ->
                util_http:return_400(Reason)
        end
    catch
        error: {badkey, MissingField} when is_binary(MissingField)->
            BadKeyError = util:to_atom(<<"missing_", MissingField/binary>>),
            log_register_error(BadKeyError),
            util_http:return_400(BadKeyError);
        error : Reason2 : Stacktrace  ->
            log_register_error(server_error),
            ?ERROR("register error: ~p, ~p", [Reason2, Stacktrace]),
            util_http:return_500()
    end.



-spec process_otp_request(RequestData :: #{}) ->
    {ok, integer()} | {error, retried_too_soon, integer()} | {error, any()}.
process_otp_request(#{raw_phone := RawPhone, lang_id := LangId, ua := UserAgent, method := MethodBin,
        ip := ClientIP, group_invite_token := GroupInviteToken, raw_data := RawData,
        protocol := Protocol}) ->
    try
        log_otp_request(RawPhone, MethodBin, UserAgent, ClientIP, Protocol),
        Phone = normalize(RawPhone),
        check_ua(UserAgent, Phone),
        Method = get_otp_method(MethodBin),
        check_invited(Phone, UserAgent, ClientIP, GroupInviteToken),
        case check_otp_allowed(Phone, ClientIP, UserAgent, Method, Protocol =:= https) of
            ok ->
                case request_otp(Phone, LangId, UserAgent, Method) of
                    {ok, RetryAfterSecs} ->
                        {ok, Phone, RetryAfterSecs};
                    {error, retried_too_soon, RetryAfterSecs} ->
                        log_request_otp_error(retried_too_soon, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
                        {error, retried_too_soon, Phone, RetryAfterSecs}
                end;
            {error, {retried_too_soon, RetryAfterSecs}} ->
                log_request_otp_error(retried_too_soon, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
                {error, retried_too_soon, Phone, RetryAfterSecs};
            {error, {Reason2, RetryAfterSecs}} ->
                log_request_otp_error(Reason2, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
                {error, dropped, Phone, RetryAfterSecs}
        end
    catch
        error : invalid_phone_number ->
            %% Make this error after we block the https api.
            ?INFO("register error: invalid_phone_number ~p", [RawData]),
            log_request_otp_error(invalid_phone_number, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, invalid_phone_number};
        error : bad_user_agent ->
            ?ERROR("register error: bad_user_agent ~p", [RawData]),
            log_request_otp_error(bad_user_agent, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, bad_user_agent};
        error : invalid_client_version ->
            ?INFO("register error: invalid_client_version ~p", [RawData]),
            log_request_otp_error(invalid_client_version, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, invalid_client_version};
        error : bad_method ->
            ?ERROR("register error: bad_method ~p", [RawData]),
            log_request_otp_error(bad_method, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, bad_method};
        error : not_invited ->
            ?INFO("request_sms error: phone not invited ~p", [RawData]),
            log_request_otp_error(not_invited, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, not_invited};
        error : sms_fail ->
            ?INFO("request_sms error: sms_failed ~p", [RawData]),
            log_request_otp_error(sms_fail, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, otp_fail};
        error : retried_too_soon ->
            ?INFO("request_otp error: sms_failed ~p", [RawData]),
            log_request_otp_error(retried_too_soon, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, retried_too_soon};
        error : voice_call_fail ->
            %% Twilio and MBird return voice_call_fail
            ?INFO("request_voice_call error: voice_call_failed ~p", [RawData]),
            log_request_otp_error(voice_call_fail, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, otp_fail};
        error : call_fail ->
            %% Twilio_verify returns call_fail
            ?INFO("request_voice_call error: voice_call_failed ~p", [RawData]),
            log_request_otp_error(voice_call_fail, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, otp_fail};
        error : tts_fail ->
            %% MBird_verify returns tts_fail
            ?INFO("request_voice_call error: voice_call_failed ~p", [RawData]),
            log_request_otp_error(voice_call_fail, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, otp_fail};
        Class : Reason : Stacktrace ->
            ?ERROR("request_sms crash: ~s\nStacktrace:~s",
                [Reason, lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            log_request_otp_error(server_error, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, internal_server_error}
    end.


%% TODO (murali@): using a map is not great. try to use the original record itself.
-spec process_register_request(RequestData :: #{}) -> {ok, #{}} | {error, any()}.
process_register_request(#{raw_phone := RawPhone, name := Name, ua := UserAgent, code := Code,
        ip := ClientIP, group_invite_token := GroupInviteToken, s_ed_pub := SEdPubB64,
        signed_phrase := SignedPhraseB64, id_key := IdentityKeyB64, sd_key := SignedKeyB64,
        otp_keys := OneTimeKeysB64, push_payload := PushPayload, raw_data := RawData,
        protocol := Protocol}) ->
    try
        Phone = normalize(RawPhone),
        check_ua(UserAgent, Phone),
        check_sms_code(Phone, Code),
        ok = delete_client_ip(ClientIP),
        ok = delete_phone_pattern(Phone, Protocol =:= https),
        LName = check_name(Name),
        SEdPubBin = base64:decode(SEdPubB64),
        check_s_ed_pub_size(SEdPubBin),
        SignedPhraseBin = base64:decode(SignedPhraseB64),
        check_signed_phrase(SignedPhraseBin, SEdPubBin),
        SPub = base64:encode(enacl:crypto_sign_ed25519_public_to_curve25519(SEdPubBin)),
        {ok, Phone, Uid} = finish_registration_spub(Phone, LName, UserAgent, SPub),
        process_whisper_keys(Uid, IdentityKeyB64, SignedKeyB64, OneTimeKeysB64),
        process_push_token(Uid, PushPayload),
        CC = mod_libphonenumber:get_region_id(Phone),
        ?INFO("registration complete uid:~s, phone:~s, country_code:~s", [Uid, Phone, CC]),
        Result = #{
            uid => Uid,
            phone => Phone,
            name => LName,
            result => ok
        },
        Result2 = case GroupInviteToken of
            undefined -> Result;
            _ -> Result#{group_invite_result => maybe_join_group(Uid, GroupInviteToken)}
        end,
        {ok, Result2}
    catch
        error : bad_user_agent ->
            ?ERROR("register error: bad_user_agent ~p", [RawData]),
            log_register_error(bad_user_agent),
            {error, bad_user_agent};
        error : invalid_phone_number ->
            ?ERROR("register error: invalid_phone_number ~p", [RawData]),
            log_register_error(invalid_phone_number),
            {error, invalid_phone_number};
        error : invalid_client_version ->
            ?ERROR("register error: invalid_client_version ~p", [RawData]),
            {error, invalid_client_version};
        error : wrong_sms_code ->
            ?INFO("register error: code mismatch data:~p", [RawData]),
            log_register_error(wrong_sms_code),
            {error, wrong_sms_code};
        error : invalid_s_ed_pub ->
            ?ERROR("register error: invalid_s_ed_pub ~p", [RawData]),
            log_register_error(invalid_s_ed_pub),
            {error, invalid_s_ed_pub};
        error : invalid_signed_phrase ->
            ?ERROR("register error: invalid_signed_phrase ~p", [RawData]),
            log_register_error(invalid_signed_phrase),
            {error, invalid_signed_phrase};
        error : unable_to_open_signed_phrase ->
            ?ERROR("register error: unable_to_open_signed_phrase ~p", [RawData]),
            log_register_error(unable_to_open_signed_phrase),
            {error, unable_to_open_signed_phrase};
        error: {wk_error, Reason} ->
            log_register_error(wk_error),
            {error, Reason};
        error: invalid_name ->
            log_register_error(invalid_name),
            {error, invalid_name};
        error : Reason : Stacktrace  ->
            log_register_error(server_error),
            ?ERROR("register error: ~p, ~p", [Reason, Stacktrace]),
            {error, internal_server_error}
    end.


-spec log_register_error(ErrorType :: atom | string()) -> ok.
log_register_error(ErrorType) ->
    stat:count("HA/account", "register_errors", 1,
        [{error, ErrorType}]),
    ok.


-spec return_retried_too_soon(Phone :: phone(), RetrySecs :: integer(), Method :: binary()) -> http_response().
return_retried_too_soon(Phone, RetrySecs, Method) ->
    CC = mod_libphonenumber:get_cc(Phone),
    stat:count("HA/account", "request_otp_errors", 1, [{error, retried_too_soon}, {cc, CC}, {method, Method}]),
    {400, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {phone, Phone},
            {retry_after_secs, RetrySecs},
            {error, retried_too_soon},
            {result, fail}
        ]})}.

-spec return_dropped(Phone :: phone(), RetrySecs :: integer(), Method :: binary()) -> http_response().
return_dropped(Phone, RetrySecs, Method) ->
    CC = mod_libphonenumber:get_cc(Phone),
    stat:count("HA/account", "request_otp_errors", 1, [{error, dropped}, {cc, CC}, {method, Method}]),
    {200, ?HEADER(?CT_JSON),
        jiffy:encode({[
            {phone, Phone},
            {retry_after_secs, RetrySecs},
            {result, ok}
        ]})}.

 -spec log_request_otp_error(ErrorType :: atom() | string(), Method :: binary() | atom(),
        RawPhone :: binary(), UserAgent :: binary(), IP :: binary(), Protocol :: atom()) -> ok.
log_request_otp_error(ErrorType, Method, RawPhone, UserAgent, ClientIP, Protocol) ->
    CleanMethod = case Method of
        <<"sms">> -> sms;
        <<"voice_call">> -> voice_call;
        _ -> unknown
    end,
    stat:count("HA/account", "request_otp_errors", 1,
        [{error, ErrorType}, {method, CleanMethod}]),

    % TODO: this code is duplicated with normalize function
    Phone = mod_libphonenumber:normalize(mod_libphonenumber:prepend_plus(RawPhone), <<"US">>),
    Event = #{
        % TODO: add log path for the successful requests, include gateway, price and other info like mcc, mnc
        result => error,
        error => ErrorType,
        phone => Phone,
        phone_raw => RawPhone,
        cc => mod_libphonenumber:get_cc(RawPhone),
        method => CleanMethod,
        user_agent => UserAgent,
        ip => ClientIP,
        protocol => Protocol
    },
    mod_client_log:log_event(<<"server.otp_request_result">>, Event),
    ok.


-spec request_otp(Phone :: phone(), LangId :: binary(), UserAgent :: binary(),
        Method :: atom()) -> {ok, integer()} | no_return(). % throws otp_fail
request_otp(Phone, LangId, UserAgent, Method) ->
    CountryCode = mod_libphonenumber:get_cc(Phone),
    case mod_sms:request_otp(Phone, LangId, UserAgent, Method) of
        {ok, _} = Ret -> Ret;
        {error, Reason} ->
            ?ERROR("could not send otp Reason: ~p Phone: ~p, cc: ~p", [Reason, Phone, CountryCode]),
            error(Reason);
        {error, Reason, RetryTs} = Error->
            ?INFO("could not send otp Reason: ~p Ts: ~p Phone: ~p, cc: ~p",
                [Reason, RetryTs, Phone, CountryCode]),
            Error
    end.


-spec check_ua(binary(), phone()) -> ok | no_return().
check_ua(UserAgent, Phone) ->
    case mod_sms_app:is_sms_app(Phone) of
        true -> 
            %% force sms_app clients to be android
            case util_ua:is_android(UserAgent) of
                true -> ok;
                false -> 
                    ?ERROR("SMSApp must be Android, got:~p", [UserAgent]),
                    error(bad_user_agent)
            end;
        false -> check_ua(UserAgent)
    end.


-spec check_ua(binary()) -> ok | no_return().
check_ua(UserAgent) ->
    case util_ua:is_valid_ua(UserAgent) of
        true ->
            case mod_client_version:is_valid_version(UserAgent) of
                true -> ok;
                false -> error(invalid_client_version) 
            end;
        false ->
            ?ERROR("Invalid UserAgent:~p", [UserAgent]),
            error(bad_user_agent)
    end.

-spec get_otp_method(binary()) -> sms | voice_call | no_return().
get_otp_method(Method) ->
    case Method of
        <<"sms">> -> sms;
        <<"voice_call">> -> voice_call;
        _ ->
            ?ERROR("Invalid Method:~p", [Method]),
            error(bad_method)
    end.

-spec check_s_ed_pub_size(SEdPub :: binary()) -> ok | error.
check_s_ed_pub_size(SEdPub) ->
    case byte_size(SEdPub) of
        32 -> ok;
        _ ->
            ?ERROR("Invalid s_ed_pub: ~p", [SEdPub]),
            error(invalid_s_ed_pub)
    end.

-spec check_signed_phrase(SignedPhrase :: binary(), SEdPub:: binary())  -> ok | error.
check_signed_phrase(SignedPhrase, SEdPub) ->
    case enacl:sign_open(SignedPhrase, SEdPub) of
        {ok, ?MSG_TO_SIGN} -> ok;
        {ok, Phrase} ->
            ?ERROR("Invalid Signed Phrase: ~p", [Phrase]),
            error(invalid_signed_phrase);
        {error, _} ->
            ?ERROR("Unable to open signed message: ~p", [base64:encode(SignedPhrase)]),
            error(unable_to_open_signed_phrase)
    end.


-spec check_name(Name :: binary()) -> binary() | any().
check_name(Name) ->
    case mod_names:check_name(Name) of
        {ok, LName} -> LName;
        {error, Reason} -> error(Reason)
    end.


-spec check_otp_allowed(Phone :: binary(), IP :: binary(), UserAgent :: binary(), Method :: atom(),
        IsHttps :: boolean())
        -> ok | {error, {Reason :: atom(), integer()}}.
check_otp_allowed(Phone, IP, UserAgent, Method, IsHttps) ->
    case mod_sms:check_otp_request_too_soon(Phone, Method) of
        false -> check_blocked(IP, Phone, UserAgent, IsHttps);
        {true, X} -> {error, {retried_too_soon, X}}
    end.


-spec check_blocked(IP :: string(), Phone :: binary(), UserAgent :: binary(), IsHttps :: boolean())
            -> ok | {error, {Reason :: atom(), RetryAfter :: integer()}}.
check_blocked(IP, Phone, UserAgent, IsHttps) ->
    IsInvited = model_invites:is_invited(Phone),
    case util:is_test_number(Phone) orelse IsInvited of
        false ->
            CC = mod_libphonenumber:get_cc(Phone),
            ?DEBUG("CC: ~p", [CC]),
            Result0 = case is_ip_in_blocklist(IP) of
                false -> false;
                {true, RetrySecs0} -> {true, {blocklist, RetrySecs0}}
            end,
            Result1 = case Result0 of
                {true, _} -> Result0;
                false ->
                    case is_ip_blocked(IP) of
                        false -> false;
                        {true, RetrySecs1} -> {true, {ip_block, RetrySecs1}}
                    end
            end,
            PhonePattern = extract_phone_pattern(Phone, CC, IsHttps),
            ?DEBUG("Phone Pattern: ~p", [PhonePattern]),
            Result2 = case Result1 of
                {true, _} -> Result1;
                false ->
                    case PhonePattern =:= Phone of
                        true -> false;
                        false ->
                            case is_phone_pattern_blocked(PhonePattern, CC, IsHttps) of
                                false -> false;
                                {true, RetrySecs2} -> {true, {phone_block, RetrySecs2}}
                            end
                    end
            end,
            ?INFO("IP: ~s Phone: ~p, CC: ~p pattern: ~p UA: ~p, blocked result: ~p, is_noise: ~p",
                [IP, Phone, CC, PhonePattern, UserAgent, Result2, not IsHttps]),
            case Result2 of
                false -> ok;
                {true, {Reason, RetrySecs3}} -> {error, {Reason, RetrySecs3}}
            end;
        true ->
            ?INFO("IP: ~s blocked result: ~p, Phone: ~p, is_invited: ~p, is_noise: ~p",
                [IP, false, Phone, IsInvited, not IsHttps]),
            ok
    end.

extract_phone_pattern(Phone, CC, IsHttps) ->
    TruncateLen = case {CC, IsHttps} of
        {<<"AD">>, true} -> 7;
        {<<"AD">>, false} -> 3;
        {<<"AF">>, true} -> 7;
        {<<"AF">>, false} -> 3;
        {<<"AZ">>, true} -> 7;
        {<<"AZ">>, false} -> 3;
        {<<"BE">>, true} -> 7;
        {<<"BE">>, false} -> 3;
        {<<"BF">>, true} -> 7;
        {<<"BF">>, false} -> 3;
        {<<"BS">>, true} -> 7;
        {<<"BS">>, false} -> 3;
        {<<"BY">>, true} -> 7;
        {<<"BY">>, false} -> 3;
        {<<"CH">>, true} -> 7;
        {<<"CH">>, false} -> 3;
        {<<"CW">>, true} -> 7;
        {<<"CW">>, false} -> 3;
        {<<"EE">>, true} -> 7;
        {<<"EE">>, false} -> 3;
        {<<"ES">>, true} -> 7;
        {<<"ES">>, false} -> 3;
        {<<"GB">>, true} -> 7;
        {<<"GB">>, false} -> 3;
        {<<"GW">>, true} -> 7;
        {<<"GW">>, false} -> 3;
        {<<"GN">>, true} -> 7;
        {<<"GN">>, false} -> 3;
        {<<"GG">>, true} -> 7;
        {<<"GG">>, false} -> 3;
        {<<"DZ">>, true} -> 7;
        {<<"DZ">>, false} -> 3;
        {<<"IQ">>, true} -> 7;
        {<<"IQ">>, false} -> 3;
        {<<"IR">>, true} -> 7;
        {<<"IR">>, false} -> 3;
        {<<"KG">>, true} -> 7;
        {<<"KG">>, false} -> 3;
        {<<"KZ">>, true} -> 7;
        {<<"KZ">>, false} -> 3;
        {<<"KW">>, true} -> 7;
        {<<"KW">>, false} -> 3;
        {<<"KE">>, true} -> 7;
        {<<"KE">>, false} -> 3;
        {<<"LT">>, true} -> 7;
        {<<"LT">>, false} -> 3;
        {<<"LV">>, true} -> 7;
        {<<"LV">>, false} -> 3;
        {<<"LS">>, true} -> 7;
        {<<"LS">>, false} -> 3;
        {<<"LK">>, true} -> 7;
        {<<"LK">>, false} -> 3;
        {<<"MD">>, true} -> 7;
        {<<"MD">>, false} -> 3;
        {<<"ML">>, true} -> 7;
        {<<"ML">>, false} -> 3;
        {<<"MR">>, true} -> 7;
        {<<"MR">>, false} -> 3;
        {<<"MK">>, true} -> 7;
        {<<"MK">>, false} -> 3;
        {<<"PK">>, true} -> 7;
        {<<"PK">>, false} -> 3;
        {<<"RU">>, true} -> 7;
        {<<"RU">>, false} -> 3;
        {<<"SD">>, true} -> 7;
        {<<"SD">>, false} -> 3;
        {<<"SN">>, true} -> 7;
        {<<"SN">>, false} -> 3;
        {<<"TN">>, true} -> 7;
        {<<"TN">>, false} -> 3;
        {<<"TR">>, true} -> 7;
        {<<"TR">>, false} -> 3;
        {<<"TZ">>, true} -> 7;
        {<<"TZ">>, false} -> 3;
        {<<"TW">>, true} -> 7;
        {<<"TW">>, false} -> 3;
        {<<"UZ">>, true} -> 7;
        {<<"UZ">>, false} -> 3;
        {<<"UA">>, true} -> 7;
        {<<"UA">>, false} -> 3;
        {_, true} -> 5;
        {_, false} -> 3
    end,
    PhonePatternLength = byte_size(Phone) - TruncateLen,
    <<PhonePattern:PhonePatternLength/binary, _Last/binary>> = Phone,
    PhonePattern.

-spec normalize(RawPhone :: binary()) -> binary() | no_return(). %throws invalid_phone_number
normalize(RawPhone) ->
    %% We explicitly ask the clients to remove the plus in this case.
    %% So, we try to re-add here before normalizing.
    % RawPhone.
    E164Phone = mod_libphonenumber:prepend_plus(RawPhone),
    case mod_libphonenumber:normalize(E164Phone, <<"US">>) of
        undefined ->
            error(invalid_phone_number);
        Phone ->
            Phone
    end.


-spec check_invited(PhoneNum :: binary(), UserAgent :: binary(), IP :: string(),
        GroupInviteToken :: binary()) -> ok | erlang:error().
check_invited(PhoneNum, UserAgent, IP, GroupInviteToken) ->
    case ?IS_INVITE_REQUIRED of
        true -> check_invited_internal(PhoneNum, UserAgent, IP, GroupInviteToken);
        false -> ok
    end.

check_invited_internal(PhoneNum, UserAgent, IP, GroupInviteToken) ->
    Invited = model_invites:is_invited(PhoneNum),
    IsTestNumber = util:is_test_number(PhoneNum),
    IsInvitedToGroup = is_group_invite_valid(GroupInviteToken),
    IsAllowedVersion = is_version_invite_opened(UserAgent),
    IsIPAllowed = is_ip_invite_opened(IP),
    IsCCAllowed = is_cc_invite_opened(PhoneNum),
    IsProduction = config:is_prod_env(),
    case Invited orelse IsInvitedToGroup orelse IsAllowedVersion orelse
            IsIPAllowed orelse IsCCAllowed of
        true -> ok;
        false ->
            case {IsProduction, IsTestNumber} of 
                {false, true} -> ok;
                {_,_} ->
                    case model_phone:get_uid(PhoneNum) of
                        {ok, undefined} ->
                            log_not_invited(PhoneNum),
                            erlang:error(not_invited);
                        {ok, _Uid} ->
                            ok
                    end
            end
    end.

-spec log_not_invited(PhoneNum :: binary()) -> ok.
log_not_invited(PhoneNum) ->
    try
        CC = mod_libphonenumber:get_cc(PhoneNum),
        NumPossibleFriends = model_contacts:get_contact_uids_size(PhoneNum),
        HasSomeone = NumPossibleFriends =/= 0,
        ?INFO("Phone: ~s (~s) is not invited. Has ~p possible friends", [PhoneNum, CC, NumPossibleFriends]),
        New = model_contacts:add_not_invited_phone(PhoneNum),
        case New of
            true ->
                stat:count("HA/registration", "not_invited", 1),
                stat:count("HA/registration", "not_invited_by_cc", 1, [{"cc", CC}]),
                stat:count("HA/registration", "not_invited_by_has_possible_friends", 1,
                        [{"has_someone", HasSomeone}]);
            false -> ok
        end,
        ok
    catch
        Class : Reason : St ->
            ?ERROR("Stacktrace: ~s", [lager:pr_stacktrace(St, {Class, Reason})])
    end.

-spec is_version_invite_opened(UserAgent :: binary()) -> boolean().
is_version_invite_opened(UserAgent) ->
    case UserAgent of
%%        <<"HalloApp/iOS1.0.79", _Rest/binary>> -> true;
%%        <<"HalloApp/79", _Rest/binary>> -> true;
        _Any -> false
    end.

-spec is_group_invite_valid(GroupInviteToken :: maybe(binary())) -> boolean().
is_group_invite_valid(undefined) ->
    false;
is_group_invite_valid(GroupInviteToken) ->
    case model_groups:get_invite_link_gid(GroupInviteToken) of
        undefined -> false;
        _Gid -> true
    end.

-spec delete_client_ip(IP :: list()) -> ok.
delete_client_ip(IP) ->
    model_ip_addresses:delete_ip_address(IP),
    %% clear timestamp on blocked ip address as well.
    model_ip_addresses:clear_blocked_ip_address(IP).

-spec delete_phone_pattern(Phone :: binary(), IsHttps :: boolean()) -> ok.
delete_phone_pattern(Phone, IsHttps) ->
    CC = mod_libphonenumber:get_region_id(Phone),
    model_phone:delete_phone_pattern(extract_phone_pattern(Phone, CC, IsHttps)).


-spec is_ip_blocked(IP :: list()) -> false | {true, integer()}.
is_ip_blocked(IP) ->
    CurrentTs = util:now(),
    {ok, {Count, LastTs}} = model_ip_addresses:get_ip_address_info(IP),
    ?DEBUG("IP: ~s, Count: ~p, LastTs: ~p, CurrentTs: ~p", [IP, Count, LastTs, CurrentTs]),
    IsIpBlocked = case {Count, LastTs} of
        {undefined, _} ->
            false;
        {_, undefined} ->
            false;
        {_, _} when Count =< ?IP_BACKOFF_THRESHOLD ->
            false;
        {_, _} ->
            NextTs = util_sms:good_next_ts_diff(Count - ?IP_BACKOFF_THRESHOLD) + LastTs,
            ?DEBUG("NexTs: ~p", [NextTs]),
            case NextTs > CurrentTs of
                true -> {true, NextTs - CurrentTs};
                false -> false
            end
    end,
    case IsIpBlocked of
        false ->
            ok = model_ip_addresses:add_ip_address(IP, CurrentTs),
            false;
        {true, _} = Result ->
            Result
    end.


-spec is_ip_in_blocklist(IP :: list()) -> false | {true, integer()}.
is_ip_in_blocklist(IP) ->
    CurrentTs = util:now(),
    case model_ip_addresses:is_ip_blocked(IP) of
        false -> false;
        {true, undefined} ->
            model_ip_addresses:record_blocked_ip_address(IP, CurrentTs),
            false;
        {true, Timestamp} ->
            %% IP is in our blocklist - so allow only 1 per block_ip_backoff_time.
            TimeDiff = CurrentTs - Timestamp - ?BLOCK_IP_BACKOFF_TIME,
            case TimeDiff >= 0 of
                true ->
                    model_ip_addresses:record_blocked_ip_address(IP, CurrentTs),
                    false;
                false ->
                    {true, 0 - TimeDiff}
            end
    end.


-spec is_phone_pattern_blocked(PhonePattern :: binary(), CC :: binary(), IsHttps :: boolean()) -> false | {true, integer()}.
is_phone_pattern_blocked(PhonePattern, CC, IsHttps) ->
    BackoffThreshold = case IsHttps of
        false -> ?PHONE_PATTERN_BACKOFF_THRESHOLD;
        true -> 0
    end,
    CurrentTs = util:now(),
    {ok, {Count, LastTs}} = model_phone:get_phone_pattern_info(PhonePattern),
    ?DEBUG("PhonePattern: ~p, CC: ~p, Count: ~p, LastTs: ~p, CurrentTs: ~p, BackoffThreshold: ~p",
        [PhonePattern, CC, Count, LastTs, CurrentTs, BackoffThreshold]),
    IsBlocked = case {Count, LastTs} of
        {undefined, _} ->
            false;
        {_, undefined} ->
            false;
        {_, _} when Count =< BackoffThreshold ->
            false;
        {_, _} ->
            NextTs = util_sms:good_next_ts_diff(Count - BackoffThreshold) + LastTs,
            ?DEBUG("NexTs: ~p", [NextTs]),
            case NextTs > CurrentTs of
                true -> {true, NextTs - CurrentTs};
                false -> false
            end
    end,
    case IsBlocked of
        false ->
              ok = model_phone:add_phone_pattern(PhonePattern, CurrentTs),
              false;
        {true, _} = Error ->
              Error
    end.


-spec is_ip_invite_opened(IP :: list()) -> boolean().
is_ip_invite_opened(IP) ->
    case inet:parse_address(IP) of
        {ok, IPTuple} ->
            case IPTuple of
                % Apple owns 17.0.0.0/8
                {17, _, _, _} -> true;
                _ -> false
            end;
        {error, _} ->
            ?WARNING("failed to parse IP: ~p", [IP]),
            false
    end.

-spec is_cc_invite_opened(Phone :: binary()) -> boolean().
is_cc_invite_opened(Phone) ->
    CC = mod_libphonenumber:get_cc(Phone),
    case CC of
        <<"BD">> -> true;  %Bangladesh
        <<"AL">> -> true;  %Israel
        <<"NL">> -> true;  %Netherlands
        <<"NZ">> -> true;  %New Zealand
        <<"DK">> -> true;  %Denmark
        <<"AT">> -> true;  %Austria
        _ -> false
    end.

-spec process_whisper_keys(Uid :: uid(), IdentityKeyB64 :: binary(), SignedKeyB64 :: binary(),
    OneTimeKeysB64 :: [binary()]) -> ok. % | or exception
process_whisper_keys(Uid, IdentityKeyB64, SignedKeyB64, OneTimeKeysB64) ->
    ?INFO("setting keys Uid: ~s", [Uid]),
    {IdentityKey, SignedKey, OneTimeKeys} = get_and_check_whisper_keys(IdentityKeyB64,
        SignedKeyB64, OneTimeKeysB64),
    ok = mod_whisper:set_keys_and_notify(Uid, IdentityKey, SignedKey, OneTimeKeys).

-spec get_and_check_whisper_keys(IdentityKeyB64 :: binary(), SignedKeyB64 :: binary(),
    OneTimeKeysB64 :: [binary()]) -> {binary(), binary(), [binary()]}.
get_and_check_whisper_keys(IdentityKeyB64, SignedKeyB64, OneTimeKeysB64) ->
    case mod_whisper:check_whisper_keys(IdentityKeyB64, SignedKeyB64, OneTimeKeysB64) of
        {error, Reason} -> error({wk_error, Reason});
        ok -> {IdentityKeyB64, SignedKeyB64, OneTimeKeysB64}
    end.

-spec update_key(binary(), binary()) -> {ok, binary(), binary()}.
update_key(Uid, SPub) ->
    stat:count("HA/account", "update_s_pub"),
    model_auth:set_spub(Uid, SPub).


-spec process_push_token(Uid :: uid(), PushPayload :: map()) -> ok.
process_push_token(Uid, PushPayload) ->
    LangId = maps:get(<<"lang_id">>, PushPayload, <<"en-US">>),
    PushToken = maps:get(<<"push_token">>, PushPayload, undefined),
    PushOs = maps:get(<<"push_os">>, PushPayload, undefined),
    case PushToken =/= undefined andalso mod_push_tokens:is_appclip_push_os(PushOs) of
        true ->
            ok = mod_push_tokens:register_push_info(Uid, PushOs, PushToken, LangId),
            ?INFO("Uid: ~p, registered push_info, os: ~p, lang_id: ~p", [Uid, PushOs, LangId]),
            ok;
        false ->
            ?INFO("Uid: ~s, could not process push token", [Uid]),
            ok
    end.


-spec finish_registration_spub(phone(), binary(), binary(), binary()) -> {ok, phone(), binary()}.
finish_registration_spub(Phone, Name, UserAgent, SPub) ->
    Host = util:get_host(),
    {ok, Uid, Action} = ejabberd_admin:check_and_register(Phone, Host, SPub, Name, UserAgent),
    %% Action = login, updates the spub.
    %% Action = register, creates a new user id and registers the user for the first time.
    log_registration(Phone, Action, UserAgent),
    {ok, Phone, Uid}.

log_registration(Phone, Action, UserAgent) ->
    case {Action, util:is_test_number(Phone)} of
        {login, false} ->
            stat:count("HA/account", "login_by_client_type", 1,
                [{client_type, util_ua:get_client_type(UserAgent)}]);
        {register, false} ->
            stat:count("HA/account", "registration_by_client_type", 1,
                [{client_type, util_ua:get_client_type(UserAgent)}]);
        {_, true} ->
            ok
    end.

log_otp_request(RawPhone, Method, UserAgent, ClientIP, Protocol) ->
    Event = #{
        raw_phone => RawPhone,
        cc => mod_libphonenumber:get_cc(RawPhone),
        method => Method,
        user_agent => UserAgent,
        ip => ClientIP,
        protocol => Protocol
    },
    mod_client_log:log_event(<<"server.otp_request">>, Event).


%% Throws error if the code is wrong
-spec check_sms_code(phone(), binary()) -> ok.
check_sms_code(Phone, Code) ->
    case mod_sms:verify_sms(Phone, Code) of
        match -> 
            ?DEBUG("Code match phone:~s code:~s", [Phone, Code]),
            ok;
        nomatch ->
            ?INFO("Codes mismatch, phone:~s, code:~s", [Phone, Code]),
            error(wrong_sms_code)
    end.

-spec maybe_join_group(Uid :: uid(), Link :: binary()) -> ok | atom().
maybe_join_group(_Uid, undefined) ->
    invalid_invite;
maybe_join_group(Uid, Link) ->
    case mod_groups:join_with_invite_link(Uid, Link) of
        {ok, _} -> ok;
        {error, Reason} -> Reason
    end.

-spec insert_blocklist() -> ok.
insert_blocklist() ->
    insert_blocklist(<<"ha_block_list_3000.txt">>, <<"ha">>).

-spec insert_blocklist(FileName :: binary(), Name :: binary()) -> ok.
insert_blocklist(FileName, Name) ->
    FullFileName = filename:join(misc:data_dir(), FileName),
    {ok, Data} = file:read_file(FullFileName),
    Ips = binary:split(Data, <<"\n">>, [global]),
    lists:foreach(
        fun(IP) ->
            model_ip_addresses:add_blocked_ip_address(IP, Name)
        end,
        Ips),
    ok.


start(_Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [{mod_sms, hard}].

-spec mod_options(binary()) -> [{atom(), term()}].
mod_options(_Host) ->
    [].
