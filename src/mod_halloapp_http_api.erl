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
    check_sms_code/6,
    check_hashcash_solution/2,
    check_attempts_by_ip/1,
    check_attempts_by_static_key/1
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
-include("monitor.hrl").

-define(MSG_TO_SIGN, <<"HALLO">>).

-define(HASHCASH_EXPIRE_IN, 21600).
-define(HASHCASH_DIFFICULTY, 10).
-define(SPAM_CC_HASHCASH_DIFFICULTY, 21).
-define(DEV_HASHCASH_DIFFICULTY, 10).
-define(HASHCASH_THRESHOLD_MS, 30 * ?SECONDS_MS).
%% allow 10 attempts to guess the code per day, 20 for test numbers
-define(MAX_SMS_CODE_ATTEMPTS, 10).
-define(DEV_MAX_SMS_CODE_ATTEMPTS, 20).
-define(MAX_IP_SMS_CODE_ATTEMPTS, 30).
-define(MAX_STATIC_KEY_SMS_CODE_ATTEMPTS, 15).

%% Allow Google to register using the following OTP. The following OTP will be given to Google
%% along with submission of new version of the App.
-define(SPECIAL_OTP_GOOGLE, <<"466453">>).
-define(SPECIAL_OTP_APPLE, <<"474663">>).


%% API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([
    check_name/1,
    process/2,
    process_hashcash_request/1,
    process_otp_request/1,
    process_register_request/1,
    insert_blocklist/0,
    insert_blocklist/2,
    create_hashcash_challenge/2
]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------


-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
process([<<"registration">>, <<"request_sms">>],
        #request{method = 'POST', data = Data, ip = {IP, _Port}, headers = Headers}) ->
    ?INFO("Invalid old request_sms request, Data: ~p, Headers: ~p", [Data, Headers]),
    process_otp_request_dummy(Data, IP, Headers);

process([<<"registration">>, <<"request_hashcash">>],
        #request{method = 'POST', data = Data, ip = {IP, _Port}, headers = Headers}) ->
    stat:count("HA/registration", "request_hashcash", 1, [{protocol, "https"}]),
    %this one isn't dummied out, but it doesn't do anything
    process_hashcash_request(Data, IP, Headers);

process([<<"registration">>, <<"request_otp">>],
        #request{method = 'POST', data = Data, ip = {IP, _Port}, headers = Headers}) ->
    UserAgent = util_http:get_user_agent(Headers),
    stat:count(util:get_stat_namespace(UserAgent) ++ "/registration",
        "request_otp_request", 1, [{protocol, "https"}]),
    process_otp_request_dummy(Data, IP, Headers);

process([<<"registration">>, <<"register2">>],
        #request{method = 'POST', data = Data, ip = {_IP, _Port}, headers = Headers}) ->
    %now dummied out - always returns fake success
    UserAgent = util_http:get_user_agent(Headers),
    stat:count(util:get_stat_namespace(UserAgent) ++ "/registration",
        "verify_otp_request", 1, [{protocol, "https"}]),
    Payload = jiffy:decode(Data, [return_maps]),
    RawPhone = maps:get(<<"phone">>, Payload),
    Phone = normalize_by_version(RawPhone, UserAgent),
    Name = maps:get(<<"name">>, Payload),
    Result = #{
            uid => util_uid:generate_uid(UserAgent),
            phone => Phone,
            name => Name,
            result => ok
    },
    {200, ?HEADER(?CT_JSON), jiffy:encode(Result)};

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

-spec process_hashcash_request(Data :: binary(), IP :: inet:ip_address(), Headers :: list()) -> http_response().
process_hashcash_request(Data, IP, Headers) ->
    try
        ?DEBUG("Data:~p", [Data]),
        ClientIP = util_http:get_ip(IP, Headers),
        Payload = jiffy:decode(Data, [return_maps]),
        CC = maps:get(<<"country_code">>, Payload, <<>>),
        RawData = Payload#{headers => Headers, ip => IP},
        RequestData = #{ip => ClientIP, raw_data => RawData, cc => CC, protocol => https},
        {ok, HashcashChallenge} =  process_hashcash_request(RequestData),
        stat:count("HA/registration", "request_hashcash_success", 1, [{protocol, "https"}]),
        {200, ?HEADER(?CT_JSON), jiffy:encode({[{hashcash_challenge, HashcashChallenge}]})}
    catch 
        error : Reason2 : Stacktrace  ->
            ?ERROR("hashcash request error: ~p, ~p", [Reason2, Stacktrace]),
            util_http:return_500()
    end.

-spec process_otp_request_dummy(Data :: binary(), IP :: inet:ip_address(), Headers :: list()) -> http_response().
process_otp_request_dummy(Data, IP, Headers) ->
    % Fake version of previous functionality - always returns 200 OK.
    % Hopefully, will help to confuse spammers.
    ?DEBUG("Data:~p", [Data]),
    UserAgent = util_http:get_user_agent(Headers),
    AppType = util_ua:get_app_type(UserAgent),
    ClientIP = util_http:get_ip(IP, Headers),
    Payload = jiffy:decode(Data, [return_maps]),
    RawPhone = maps:get(<<"phone">>, Payload),
    MethodBin = maps:get(<<"method">>, Payload, <<"sms">>),
    LangId = maps:get(<<"lang_id">>, Payload, <<"en-US">>),
    HashcashSolution = maps:get(<<"hashcash_solution">>, Payload, <<>>),
    HashcashSolutionTimeTakenMs = maps:get(<<"hashcash_solution_time_taken_ms">>, Payload, -1),
    PhoneCC = mod_libphonenumber:get_region_id(RawPhone),
    IPCC = mod_geodb:lookup(ClientIP),
    ?INFO("app type: ~p, raw_phone:~p, ua:~p ip:~s method: ~s, langId: ~p, Phone CC: ~p IP CC: ~p "
        "Hashcash solution: ~p time taken: ~pms payload:~p ",
        [AppType, RawPhone, UserAgent, ClientIP, MethodBin, LangId, PhoneCC, IPCC, HashcashSolution,
        HashcashSolutionTimeTakenMs, Payload]),
    Phone = normalize_by_version(RawPhone, UserAgent),
    return_dropped(Phone, 30, MethodBin, AppType).

-spec process_hashcash_request(RequestData :: map()) -> {ok, binary()}.
process_hashcash_request(#{cc := CC, ip := ClientIP}) ->
    Challenge = create_hashcash_challenge(CC, ClientIP),
    ?INFO("CC: ~p, IP: ~p, Challenge: ~p", [CC, ClientIP, Challenge]),
    {ok, Challenge}.

-spec create_hashcash_challenge(CC :: any(), _IP :: any()) -> binary().
create_hashcash_challenge(CC, _IP) ->
    Challenge = util_hashcash:construct_challenge(get_hashcash_difficulty(CC), ?HASHCASH_EXPIRE_IN), 
    ok = model_phone:add_hashcash_challenge(Challenge),
    Challenge.

get_hashcash_difficulty(CC) ->
    CCBasedDifficulty = case CC of
        <<"AZ">> -> ?SPAM_CC_HASHCASH_DIFFICULTY;
        <<"SD">> -> ?SPAM_CC_HASHCASH_DIFFICULTY;
        <<"VN">> -> ?SPAM_CC_HASHCASH_DIFFICULTY;
        <<"NG">> -> ?SPAM_CC_HASHCASH_DIFFICULTY;
        <<"LK">> -> ?SPAM_CC_HASHCASH_DIFFICULTY;
        <<"BD">> -> ?SPAM_CC_HASHCASH_DIFFICULTY;
        <<"JO">> -> ?SPAM_CC_HASHCASH_DIFFICULTY;
        <<"OM">> -> ?SPAM_CC_HASHCASH_DIFFICULTY;
        <<"SN">> -> ?SPAM_CC_HASHCASH_DIFFICULTY;
        <<"KG">> -> ?SPAM_CC_HASHCASH_DIFFICULTY;
        <<"PK">> -> ?SPAM_CC_HASHCASH_DIFFICULTY;
        <<"PH">> -> ?SPAM_CC_HASHCASH_DIFFICULTY;
        <<"UZ">> -> ?SPAM_CC_HASHCASH_DIFFICULTY;
        undefined -> ?SPAM_CC_HASHCASH_DIFFICULTY;
        _ -> ?HASHCASH_DIFFICULTY
    end,
    case config:get_hallo_env() of
        prod -> CCBasedDifficulty;
        _ -> ?DEV_HASHCASH_DIFFICULTY
    end.

-spec process_otp_request(RequestData :: map()) ->
    {ok, phone(), integer(), boolean()} | {error, retried_too_soon | dropped, phone(), integer()} | {error, any()}.
process_otp_request(#{raw_phone := RawPhone, lang_id := LangId, ua := UserAgent, method := MethodBin,
        ip := ClientIP, raw_data := RawData,
        protocol := Protocol} = RequestData) ->
    try
        RemoteStaticKey = maps:get(remote_static_key, RequestData, undefined),
        HashcashSolution = maps:get(hashcash_solution, RequestData, <<>>),
        CampaignId = maps:get(campaign_id, RequestData, <<"undefined">>),
        HashcashSolutionTimeTakenMs = maps:get(hashcash_solution_time_taken_ms, RequestData, 0),
        log_otp_request(RawPhone, MethodBin, UserAgent, ClientIP, Protocol),
        check_ua(UserAgent),
        Phone = normalize_by_version(RawPhone, UserAgent),
        CC = mod_libphonenumber:get_region_id(Phone),
        check_hashcash_cc(CC, UserAgent, HashcashSolution, HashcashSolutionTimeTakenMs),
        Method = get_otp_method(MethodBin),
        ?INFO("Phone: ~s, UserAgent: ~s, Campaign Id: ~s", [Phone, UserAgent, CampaignId]),
        case otp_checker:check(Phone, ClientIP, UserAgent, Method, Protocol, RemoteStaticKey) of
            ok ->
                {ok, RetryAfterSecs, IsPastUndelivered} =
                    request_otp(Phone, LangId, UserAgent, Method, CampaignId),
                {ok, Phone, RetryAfterSecs, IsPastUndelivered};
            {error, retried_too_soon, RetryAfterSecs} ->
                log_request_otp_error(retried_too_soon, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
                {error, retried_too_soon, Phone, RetryAfterSecs};
            {block, BlockedReason, _ExtraInfo} ->
                log_request_otp_error(BlockedReason, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
                {error, dropped, Phone, 30} % 30 is the default success
        end
    catch
        error : invalid_phone_number ->
            %% Make this error after we block the https api.
            ?INFO("register error: invalid_phone_number ~p", [RawData]),
            log_request_otp_error(invalid_phone_number, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, invalid_phone_number};
        error : invalid_country_code ->
            ?INFO("register error: invalid_country_code ~p", [RawData]),
            log_request_otp_error(invalid_country_code, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, invalid_country_code};
        error : invalid_length ->
            ?INFO("register error: invalid_length ~p", [RawData]),
            log_request_otp_error(invalid_length, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, invalid_length};
        error : line_type_voip ->
            ?INFO("register error: line_type_voip ~p", [RawData]),
            log_request_otp_error(line_type_voip, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, line_type_voip};
        error : line_type_fixed ->
            ?INFO("register error: line_type_fixed ~p", [RawData]),
            log_request_otp_error(line_type_fixed, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, line_type_fixed};
        error : line_type_other ->
            ?INFO("register error: line_type_other ~p", [RawData]),
            log_request_otp_error(line_type_other, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, line_type_other};
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
        error : invalid_hashcash_nonce ->
            ?INFO("invalid hashcash nonce ~p", [RawData]),
            log_request_otp_error(invalid_hashcash_nonce, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, invalid_hashcash_nonce};
        error : wrong_hashcash_solution ->
            ?INFO("wrong hashcash solution ~p", [RawData]),
            log_request_otp_error(wrong_hashcash_solution, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, wrong_hashcash_solution};
        Class : Reason : Stacktrace ->
            ?ERROR("request_sms crash: ~p\nStacktrace:~s",
                [Reason, lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            log_request_otp_error(server_error, MethodBin, RawPhone, UserAgent, ClientIP, Protocol),
            {error, internal_server_error}
    end.

%% TODO (murali@): using a map is not great. try to use the original record itself.
-spec process_register_request(RequestData :: map()) -> {ok, map()} | {error, any()}.
process_register_request(#{raw_phone := RawPhone, ua := UserAgent, code := Code,
        ip := ClientIP, group_invite_token := GroupInviteToken, s_ed_pub := SEdPubB64,
        signed_phrase := SignedPhraseB64, id_key := IdentityKeyB64, sd_key := SignedKeyB64,
        otp_keys := OneTimeKeysB64, push_payload := PushPayload, raw_data := RawData,
        protocol := Protocol} = RequestData) ->
    AppType = util_ua:get_app_type(UserAgent),
    try
        RemoteStaticKey = maps:get(remote_static_key, RequestData, undefined),
        CampaignId = maps:get(campaign_id, RequestData, <<"undefined">>),
        check_ua(UserAgent),
        Phone = normalize_by_version(RawPhone, UserAgent),
        check_sms_code(Phone, AppType, ClientIP, Protocol, Code, RemoteStaticKey),
        ok = otp_checker:otp_delivered(Phone, ClientIP, Protocol, RemoteStaticKey),
        SEdPubBin = base64:decode(SEdPubB64),
        check_s_ed_pub_size(SEdPubBin),
        SignedPhraseBin = base64:decode(SignedPhraseB64),
        check_signed_phrase(SignedPhraseBin, SEdPubBin),
        SPub = base64:encode(enacl:crypto_sign_ed25519_public_to_curve25519(SEdPubBin)),
        {ok, Phone, Uid} = finish_registration_spub(Phone, UserAgent, SPub, CampaignId),
        process_whisper_keys(Uid, IdentityKeyB64, SignedKeyB64, OneTimeKeysB64),
        process_push_token(Uid, PushPayload),
        CC = mod_libphonenumber:get_region_id(Phone),
        Name = case model_accounts:get_name(Uid) of
            {ok, undefined} -> <<>>;
            {ok, AccountName} -> AccountName
        end,
        Username = case model_accounts:get_username(Uid) of
            {ok, undefined} -> <<>>;
            {ok, AccountUsername} -> AccountUsername
        end,
        ?INFO("registration complete uid: ~s phone: ~s country_code: ~s campaign_id: ~s",
            [Uid, Phone, CC, CampaignId]),
        Result = #{
            uid => Uid,
            phone => Phone,
            result => ok,
            name => Name,
            username => Username
        },
        Result2 = case GroupInviteToken of
            undefined -> Result;
            _ -> Result#{group_invite_result => maybe_join_group(Uid, GroupInviteToken)}
        end,
        {ok, Result2}
    catch
        error : bad_user_agent ->
            ?ERROR("register error: bad_user_agent ~p", [RawData]),
            log_register_error(bad_user_agent, AppType),
            {error, bad_user_agent};
        error : invalid_phone_number ->
            ?ERROR("register error: invalid_phone_number ~p", [RawData]),
            log_register_error(invalid_phone_number, AppType),
            {error, invalid_phone_number};
        error : invalid_country_code ->
            ?ERROR("register error: invalid_country_code ~p", [RawData]),
            log_register_error(invalid_country_code, AppType),
            {error, invalid_country_code};
        error : invalid_length ->
            ?ERROR("register error: invalid_length ~p", [RawData]),
            log_register_error(invalid_length, AppType),
            {error, invalid_length};
        error : line_type_voip ->
            ?ERROR("register error: line_type_voip ~p", [RawData]),
            log_register_error(line_type_voip, AppType),
            {error, line_type_voip};
        error : line_type_fixed ->
            ?ERROR("register error: line_type_fixed ~p", [RawData]),
            log_register_error(line_type_fixed, AppType),
            {error, line_type_fixed};
        error : line_type_other ->
            ?ERROR("register error: line_type_other ~p", [RawData]),
            log_register_error(line_type_other, AppType),
            {error, line_type_other};
        error : invalid_client_version ->
            ?ERROR("register error: invalid_client_version ~p", [RawData]),
            {error, invalid_client_version};
        error : wrong_sms_code ->
            ?INFO("register error: code mismatch data:~p", [RawData]),
            log_register_error(wrong_sms_code, AppType),
            {error, wrong_sms_code};
        error : invalid_s_ed_pub ->
            ?ERROR("register error: invalid_s_ed_pub ~p", [RawData]),
            log_register_error(invalid_s_ed_pub, AppType),
            {error, invalid_s_ed_pub};
        error : invalid_signed_phrase ->
            ?ERROR("register error: invalid_signed_phrase ~p", [RawData]),
            log_register_error(invalid_signed_phrase, AppType),
            {error, invalid_signed_phrase};
        error : unable_to_open_signed_phrase ->
            ?ERROR("register error: unable_to_open_signed_phrase ~p", [RawData]),
            log_register_error(unable_to_open_signed_phrase, AppType),
            {error, unable_to_open_signed_phrase};
        error: {wk_error, Reason} ->
            log_register_error(wk_error, AppType),
            {error, Reason};
        error: invalid_name ->
            log_register_error(invalid_name, AppType),
            {error, invalid_name};
        error: too_many_sms_code_checks ->
            log_register_error(too_many_sms_code_checks, AppType),
            %% Specify new error reason in the spec
            {error, wrong_sms_code};
        error : Reason : Stacktrace  ->
            log_register_error(server_error, AppType),
            ?ERROR("register error: ~p, ~p", [Reason, Stacktrace]),
            {error, internal_server_error}
    end.


-spec log_register_error(ErrorType :: atom() | string(), AppType :: app_type()) -> ok.
log_register_error(ErrorType, AppType) ->
    stat:count(util:get_stat_namespace(AppType) ++ "/account", "register_errors", 1,
        [{error, ErrorType}]),
    ok.

-spec return_dropped(Phone :: phone(), RetrySecs :: integer(), Method :: binary(),
    AppType :: app_type()) -> http_response().
return_dropped(Phone, RetrySecs, Method, AppType) ->
    CC = mod_libphonenumber:get_cc(Phone),
    stat:count(util:get_stat_namespace(AppType) ++ "/account", "request_otp_errors", 1,
        [{error, dropped}, {cc, CC}, {method, Method}]),
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
    stat:count(util:get_stat_namespace(UserAgent) ++ "/account", "request_otp_errors", 1,
            [{error, ErrorType}, {method, CleanMethod}]),
    % TODO: this code is duplicated with normalize function
    Phone = mod_libphonenumber:normalized_number(mod_libphonenumber:prepend_plus(RawPhone), <<"US">>),
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
    ha_events:log_event(<<"server.otp_request_result">>, Event),
    ok.


-spec request_otp(Phone :: phone(), LangId :: binary(), UserAgent :: binary(),
        Method :: atom(), CampaignId :: binary()) -> {ok, integer(), boolean()} | no_return(). % throws otp_fail
request_otp(Phone, LangId, UserAgent, Method, CampaignId) ->
    CountryCode = mod_libphonenumber:get_cc(Phone),
    case mod_sms:request_otp(Phone, LangId, UserAgent, Method, CampaignId) of
        {ok, _, _} = Ret -> Ret;
        {error, Reason} ->
            ?ERROR("could not send otp Reason: ~p Phone: ~p, cc: ~p", [Reason, Phone, CountryCode]),
            error(Reason)
    end.

-spec check_hashcash_cc(CC :: binary(), UserAgent :: binary(), Solution :: binary(), TimeTakenMs :: integer()) -> ok | no_return().
check_hashcash_cc(CC, UserAgent, Solution, TimeTakenMs) ->
    case util_sms:is_hashcash_enabled(UserAgent, Solution) andalso CC =/= <<"IR">> of
        true ->
            check_hashcash_solution_throw_error(Solution, TimeTakenMs);
        false ->
            HashcashResponse = check_hashcash_solution(Solution, TimeTakenMs),
            ?INFO("hashcash solution: ~p, Time taken: ~pms, Response: ~p",
                [Solution, TimeTakenMs, HashcashResponse])
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

% throws phone number errors (invalid length, invalid country code, unknown number type) depending on version
-spec normalize_by_version(RawPhone :: binary(), UserAgent :: binary()) -> binary() | no_return().
normalize_by_version(RawPhone, UserAgent) ->
    ClientType = util_ua:get_client_type(UserAgent),
    % Android clients cannot currently handle new errors
    IsValidUA = case ClientType of
        android -> false;
        ios -> util_ua:is_version_greater_than(UserAgent, <<"HalloApp/iOS1.19.0">>)
    end,
    case {normalize(RawPhone), IsValidUA} of
        {{error, ErrMsg}, true} ->
            error(ErrMsg);
        {{error, _}, false} ->
            error(invalid_phone_number);
        {Phone, _} ->
            Phone
    end.


-spec normalize(RawPhone :: binary()) -> binary() | {error, atom()}.
normalize(RawPhone) ->
    %% We explicitly ask the clients to remove the plus in this case.
    %% So, we try to re-add here before normalizing.
    % RawPhone.
    E164Phone = mod_libphonenumber:prepend_plus(RawPhone),
    case mod_libphonenumber:normalize(E164Phone, <<"US">>) of
        {error, ErrMsgRaw} ->
            ErrMsg = case ErrMsgRaw of
                invalid_country_code -> invalid_country_code;
                too_short -> invalid_length;
                too_long -> invalid_length;
                invalid_length -> invalid_length;
                % TODO: Change back to voip error after protobuf bug is fixed
                line_type_voip -> line_type_other;
                line_type_fixed -> line_type_fixed;
                line_type_other -> line_type_other;
                _ -> invalid_phone_number
            end,
            {error, ErrMsg};
        {ok, Phone} ->
            Phone
    end.

check_hashcash_solution_throw_error(HashcashSolution, HashcashSolutionTimeTakenMs) ->
    case check_hashcash_solution(HashcashSolution, HashcashSolutionTimeTakenMs) of
        ok -> ok;
        {error, Reason} ->
            error(Reason)
    end.

-spec check_hashcash_solution(HashcashSolution :: binary(), HashcashSolutionTimeTakenMs :: integer())
      -> ok | {error, atom()}.
check_hashcash_solution(HashcashSolution, HashcashSolutionTimeTakenMs) ->
    ?INFO("Hashcash solution took: ~p ms", [HashcashSolutionTimeTakenMs]),
    case HashcashSolutionTimeTakenMs > ?HASHCASH_THRESHOLD_MS of
        true ->
            ?ERROR("Hashcash solution took > 30 seconds, Time taken: ~pms", [HashcashSolutionTimeTakenMs]);
        false -> ok
    end,
    case util_hashcash:extract_challenge(HashcashSolution) of
        {error, wrong_hashcash_solution} = Error ->
            Error;
        {Difficulty, HashcashChallenge} ->
            check_hashcash_challenge_validity(Difficulty, HashcashChallenge, HashcashSolution)
    end.

check_hashcash_challenge_validity(Difficulty, Challenge, Solution) ->
    case model_phone:delete_hashcash_challenge(Challenge) of
        not_found -> {error, invalid_hashcash_nonce};
        ok ->
           case util_hashcash:validate_solution(Difficulty, Solution) of
                true -> ok;
                _ -> {error, wrong_hashcash_solution}
            end
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


-spec process_push_token(Uid :: uid(), PushPayload :: map()) -> ok.
process_push_token(Uid, PushPayload) ->
    LangId = maps:get(<<"lang_id">>, PushPayload, <<"en-US">>),
    ZoneOffset = maps:get(<<"zoneOffset">>, PushPayload, undefined),
    PushToken = maps:get(<<"push_token">>, PushPayload, undefined),
    %% TODO: rename this field to token_type.
    PushTokenType = maps:get(<<"push_os">>, PushPayload, undefined),
    case PushToken =/= undefined andalso mod_push_tokens:is_appclip_token_type(PushTokenType) of
        true ->
            ok = mod_push_tokens:register_push_info(Uid, PushTokenType, PushToken, LangId, ZoneOffset),
            ?INFO("Uid: ~p, registered push_info, token_type: ~p, lang_id: ~p, ZoneOffset: ~p", [Uid, PushTokenType, LangId, ZoneOffset]),
            ok;
        false ->
            ok
    end.


-spec finish_registration_spub(phone(), binary(), binary(), binary()) -> {ok, phone(), binary()}.
finish_registration_spub(Phone, UserAgent, SPub, CampaignId) ->
    Host = util:get_host(),
    {ok, Uid, Action} = ejabberd_auth:check_and_register(
        Phone, Host, SPub, UserAgent, CampaignId),
    ?INFO("Phone: ~s, UserAgent: ~s, Campaign Id: ~s", [Phone, UserAgent, CampaignId]),
    %% Action = login, updates the spub.
    %% Action = register, creates a new user id and registers the user for the first time.
    log_registration(Phone, Action, UserAgent),
    {ok, Phone, Uid}.

log_registration(Phone, Action, UserAgent) ->
    StatNamespace = util:get_stat_namespace(UserAgent),
    case {Action, util:is_test_number(Phone)} of
        {login, false} ->
            stat:count(StatNamespace ++ "/account", "login_by_client_type", 1,
                [{client_type, util_ua:get_client_type(UserAgent)}]);
        {register, false} ->
            stat:count(StatNamespace ++ "/account", "registration_by_client_type", 1,
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
    ha_events:log_event(<<"server.otp_request">>, Event).


%% Throws error if the code is wrong
-spec check_sms_code(phone(), app_type(), binary(), atom(), binary(), binary()) -> ok.
check_sms_code(Phone, AppType, ClientIP, Protocol, Code, RemoteStaticKey) ->
    check_excessive_sms_code_attempts(Phone, AppType, ClientIP, RemoteStaticKey),
    IsGoogleAndValid = util_sms:is_google_request(Phone, ClientIP, Protocol) andalso
        Code =:= ?SPECIAL_OTP_GOOGLE,
    IsAppleAndValid = util_sms:is_apple_request(Phone, ClientIP, Protocol) andalso
        Code =:= ?SPECIAL_OTP_APPLE,
    case IsGoogleAndValid orelse IsAppleAndValid of
        true ->
            ?INFO("Matched OTP for Google/Apple, Phone: ~p, IP: ~p, Code: ~p", [Phone, ClientIP, Code]),
            ok;
        false ->
            case mod_sms:verify_sms(Phone, AppType, Code) of
                match -> 
                    ?DEBUG("Code match phone:~s code:~s", [Phone, Code]),
                    ok;
                nomatch ->
                    ?INFO("Codes mismatch, phone:~s, code:~s", [Phone, Code]),
                    error(wrong_sms_code)
            end
    end.

% Throws error if too many attempts
-spec check_excessive_sms_code_attempts(Phone :: binary(), AppType :: app_type(), ClientIP :: binary(), StaticKey :: binary()) -> ok | no_return().
check_excessive_sms_code_attempts(Phone, AppType, IP, StaticKey) ->
    case util:is_monitor_phone(Phone) of
        true -> ok;
        false ->
            check_attempts_by_phone(Phone, AppType),
            check_attempts_by_ip(IP),
            check_attempts_by_static_key(StaticKey)
    end,
    ok.


-spec check_attempts_by_phone(Phone :: binary(), AppType :: app_type()) -> ok | no_return().
check_attempts_by_phone(Phone, AppType) ->
    NumAttempts = model_phone:add_phone_code_attempt(Phone, AppType, util:now()),
    ?INFO("Phone: ~s has made ~p attempts to guess the sms code", [Phone, NumAttempts]),
    MaxSMSAttempts = case util:is_test_number(Phone) of
        true -> ?DEV_MAX_SMS_CODE_ATTEMPTS;
        false -> ?MAX_SMS_CODE_ATTEMPTS
    end,
    case NumAttempts > MaxSMSAttempts of
        true ->
            ?ERROR("Too many sms code attempts Phone: ~p NumAttempts: ~p", [Phone, NumAttempts]),
            error(too_many_sms_code_checks);
        false ->
            ok
    end.

-spec check_attempts_by_ip(IP :: binary()) -> ok | no_return().
check_attempts_by_ip(IP) ->
    NumAttempts = model_ip_addresses:add_ip_code_attempt(IP, util:now()),
    ?INFO("IP: ~s has made ~p attempts to guess the sms code", [IP, NumAttempts]),
    case NumAttempts > ?MAX_IP_SMS_CODE_ATTEMPTS of
        true ->
            ?ERROR("Too many sms code attempts Ip: ~p NumAttempts: ~p", [IP, NumAttempts]),
            error(too_many_sms_code_checks);
        false ->
            ok
    end.


-spec check_attempts_by_static_key(StaticKey :: binary()) -> ok | no_return().
check_attempts_by_static_key(StaticKey) ->
    NumAttempts = model_auth:add_static_key_code_attempt(StaticKey, util:now()),
    ?INFO("Static Key: ~p has made ~p attempts to guess the sms code", [StaticKey, NumAttempts]),
    case NumAttempts > ?MAX_STATIC_KEY_SMS_CODE_ATTEMPTS of
        true ->
            ?ERROR("Too many sms code attempts Static Key: ~p NumAttempts: ~p", [StaticKey, NumAttempts]),
            error(too_many_sms_code_checks);
        false ->
            ok
    end,
    ok.


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
    [{mod_sms, hard}, {mod_geodb, hard}].

-spec mod_options(binary()) -> [{atom(), term()}].
mod_options(_Host) ->
    [].
