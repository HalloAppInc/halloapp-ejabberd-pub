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

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").
-include("account.hrl").
-include("ha_types.hrl").
-include("whisper.hrl").
-include("sms.hrl").
-include("invites.hrl").

-define(MSG_TO_SIGN, <<"HALLO">>).

%% API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([
    process/2,
    check_blocked/2  %% for testing
]).

%% TODO: cleanup old code in this file and old password related stuff.

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------


-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
process([<<"registration">>, <<"request_sms">>],
        #request{method = 'POST', data = Data, ip = {IP, _Port}, headers = Headers}) ->
    process_otp_request(Data, IP, Headers, false);

process([<<"registration">>, <<"request_otp">>],
        #request{method = 'POST', data = Data, ip = {IP, _Port}, headers = Headers}) ->
    process_otp_request(Data, IP, Headers, true);

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
        SEdPub = maps:get(<<"s_ed_pub">>, Payload),
        SignedPhrase = maps:get(<<"signed_phrase">>, Payload),
        GroupInviteToken = maps:get(<<"group_invite_token">>, Payload, undefined),
        Phone = normalize(RawPhone),

        check_ua(UserAgent),
        check_sms_code(Phone, Code),
        ok = delete_client_ip(ClientIP, Phone),
        LName = check_name(Name),

        SEdPubBin = base64:decode(SEdPub),
        check_s_ed_pub_size(SEdPubBin),
        SignedPhraseBin = base64:decode(SignedPhrase),
        check_signed_phrase(SignedPhraseBin, SEdPubBin),

        SPub = base64:encode(enacl:crypto_sign_ed25519_public_to_curve25519(SEdPubBin)),

        {ok, Phone, Uid} = finish_registration_spub(Phone, LName, UserAgent, SPub),
        process_whisper_keys(Uid, Payload),
        process_push_token(Uid, Payload),
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
        {200, ?HEADER(?CT_JSON), jiffy:encode(Result2)}
    catch
        % TODO: This code is getting out of hand... Figure out how to simplify the error handling
        error : bad_user_agent ->
            ?ERROR("register error: bad_user_agent ~p", [Headers]),
            log_register_error(bad_user_agent),
            util_http:return_400();
        error : invalid_phone_number ->
            ?ERROR("register error: invalid_phone_number ~p", [Headers]),
            log_request_otp_error(invalid_phone_number, sms),
            util_http:return_400(invalid_phone_number);
        error : invalid_client_version ->
            ?ERROR("register error: invalid_client_version ~p", [Headers]),
            util_http:return_400(invalid_client_version);
        error : wrong_sms_code ->
            ?INFO("register error: code mismatch data:~s", [Data]),
            log_register_error(wrong_sms_code),
            util_http:return_400(wrong_sms_code);
        error : invalid_s_ed_pub ->
            ?ERROR("register error: invalid_s_ed_pub ~p", [Data]),
            log_register_error(invalid_s_ed_pub),
            util_http:return_400(invalid_s_ed_pub);
        error : invalid_signed_phrase ->
            ?ERROR("register error: invalid_signed_phrase ~p", [Data]),
            log_register_error(invalid_signed_phrase),
            util_http:return_400(invalid_signed_phrase);
        error : unable_to_open_signed_phrase ->
            ?ERROR("register error: unable_to_open_signed_phrase ~p", [Data]),
            log_register_error(unable_to_open_signed_phrase),
            util_http:return_400(unable_to_open_signed_phrase);
        error: {badkey, MissingField} when is_binary(MissingField)->
            BadKeyError = util:to_atom(<<"missing_", MissingField/binary>>),
            log_register_error(BadKeyError),
            util_http:return_400(BadKeyError);
        error: {wk_error, Reason} ->
            log_register_error(wk_error),
            util_http:return_400(Reason);
        error: invalid_name ->
            log_register_error(invalid_name),
            util_http:return_400(invalid_name);
        error : Reason : Stacktrace  ->
            log_register_error(server_error),
            ?ERROR("register error: ~p, ~p", [Reason, Stacktrace]),
            util_http:return_500()
    end;

%% Return the group name based on group_invite_token
process([<<"registration">>, <<"get_group_info">>],
        #request{method = 'POST', data = Data, ip = {IP, _Port}, headers = Headers}) ->
    try
        ClientIP = util_http:get_ip(IP, Headers),
        UserAgent = util_http:get_user_agent(Headers),
        ?INFO("get_group_info request: r:~p ip:~s ua:~s", [Data, ClientIP, UserAgent]),
        Payload = jiffy:decode(Data, [return_maps]),
        GroupInviteToken = maps:get(<<"group_invite_token">>, Payload),

        check_ua(UserAgent),
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
        error : bad_user_agent ->
            ?ERROR("get_group_info error: bad_user_agent ~p", [Headers]),
            util_http:return_400();
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

-spec process_otp_request(Data :: string(), IP :: string(), Headers :: list(),
    MethodInRequest :: boolean()) -> http_response().
process_otp_request(Data, IP, Headers, MethodInRequest) ->
    try
        ?DEBUG("Data:~p", [Data]),
        UserAgent = util_http:get_user_agent(Headers),
        ClientIP = util_http:get_ip(IP, Headers),
        Payload = jiffy:decode(Data, [return_maps]),
        RawPhone = maps:get(<<"phone">>, Payload),
        Method = case MethodInRequest of
            false -> <<"sms">>;
            _ -> maps:get(<<"method">>, Payload, <<"sms">>)
        end,
        LangId = maps:get(<<"lang_id">>, Payload, <<"en-US">>),
        GroupInviteToken = maps:get(<<"group_invite_token">>, Payload, undefined),
        ?INFO("raw_phone:~p, ua:~p ip:~s method: ~s, langId: ~p, payload:~p ",
            [RawPhone, UserAgent, ClientIP, Method, LangId, Payload]),
        Phone = normalize(RawPhone),

        check_ua(UserAgent),
        Method2 = get_otp_method(Method),
        check_invited(Phone, UserAgent, ClientIP, GroupInviteToken),
        case check_blocked(ClientIP, Phone) of
            ok ->
                case request_otp(Phone, LangId, UserAgent, Method2) of
                    {ok, RetryAfterSecs} ->
                        {200, ?HEADER(?CT_JSON),
                            jiffy:encode({[
                                {phone, Phone},
                                {retry_after_secs, RetryAfterSecs},
                                {result, ok}
                            ]})};
                    {error, retried_too_soon, RetrySecs} ->
                        {400, ?HEADER(?CT_JSON),
                            jiffy:encode({[
                                {phone, Phone},
                                {retry_after_secs, RetrySecs},
                                {error, retried_too_soon},
                                {result, fail}
                            ]})}
                end;
            {error, retried_too_soon, RetrySecs} ->
                {400, ?HEADER(?CT_JSON),
                    jiffy:encode({[
                        {phone, Phone},
                        {retry_after_secs, RetrySecs},
                        {error, retried_too_soon},
                        {result, fail}
                    ]})}
        end
    catch
        error : ip_blocked ->
            ?ERROR("register error: ip_blocked ~p", [Headers]),
            log_request_otp_error(ip_blocked, sms),
            util_http:return_400();
        error : invalid_phone_number ->
            ?ERROR("register error: invalid_phone_number ~p", [Headers]),
            log_request_otp_error(invalid_phone_number, MethodInRequest),
            util_http:return_400(invalid_phone_number);
        error : bad_user_agent ->
            ?ERROR("register error: bad_user_agent ~p", [Headers]),
            log_request_otp_error(bad_user_agent, sms),
            util_http:return_400();
        error : invalid_client_version ->
            ?ERROR("register error: invalid_client_version ~p", [Headers]),
            util_http:return_400(invalid_client_version);
        error : bad_method ->
            ?ERROR("register error: bad_method ~p", [Data]),
            util_http:return_400(bad_method);
        error: not_invited ->
            ?INFO("request_sms error: phone not invited ~p", [Data]),
            log_request_otp_error(not_invited, sms),
            util_http:return_400(not_invited);
        error : sms_fail ->
            ?INFO("request_sms error: sms_failed ~p", [Data]),
            log_request_otp_error(sms_fail, sms),
            case MethodInRequest of
                false -> util_http:return_400(sms_fail);
                _ -> util_http:return_400(otp_fail)
            end;
        error : retried_too_soon ->
            ?INFO("request_otp error: sms_failed ~p", [Data]),
            log_request_otp_error(retried_too_soon, otp),
            util_http:return_400(retried_too_soon);
        error : voice_call_fail ->
            %% Twilio and MBird return voice_call_fail
            ?INFO("request_voice_call error: voice_call_failed ~p", [Data]),
            log_request_otp_error(voice_call_fail, voice_call),
            util_http:return_400(otp_fail);
        error : call_fail ->
            %% Twilio_verify returns call_fail
            ?INFO("request_voice_call error: voice_call_failed ~p", [Data]),
            log_request_otp_error(voice_call_fail, voice_call),
            util_http:return_400(otp_fail);
        Class : Reason : Stacktrace  ->
            ?ERROR("request_sms crash: ~s\nStacktrace:~s",
                [Reason, lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            log_request_otp_error(server_error, otp),
            util_http:return_500()
    end.

-spec log_register_error(ErrorType :: atom | string()) -> ok.
log_register_error(ErrorType) ->
    stat:count("HA/account", "register_errors", 1,
        [{error, ErrorType}]),
    ok.


-spec log_request_otp_error(ErrorType :: atom() | string(), Method :: atom()) -> ok.
log_request_otp_error(ErrorType, sms) ->
    stat:count("HA/account", "request_sms_errors", 1,
        [{error, ErrorType}]),
    ok;
log_request_otp_error(ErrorType, Method) ->
    stat:count("HA/account", "request_otp_errors", 1,
        [{error, ErrorType}, {method, Method}]),
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


-spec check_ua(binary()) -> ok | no_return().
check_ua(UserAgent) ->
    case util_ua:is_hallo_ua(UserAgent) of
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
check_name(<<"">>) ->
    error(invalid_name);
check_name(Name) when is_binary(Name) ->
    LName = string:slice(Name, 0, ?MAX_NAME_SIZE),
    case LName =:= Name of
        false ->
            ?WARNING("Truncating user name to |~s| size was: ~p", [LName, byte_size(Name)]);
        true ->
            ok
    end,
    LName;
check_name(_) ->
    error(invalid_name).

-spec check_blocked(IP :: string(), Phone :: binary()) -> ok | {error, retried_too_soon, integer()}.
check_blocked(IP, Phone) ->
    CC = mod_libphonenumber:get_cc(Phone),
    case is_ip_blocked(IP, CC) of
        {true, RetrySecs} -> {error, retried_too_soon, RetrySecs};
        false -> ok
    end.


-spec normalize(RawPhone :: binary()) -> binary() | no_return(). %throws invalid_phone_number
normalize(RawPhone) ->
    %% We explicitly ask the clients to remove the plus in this case.
    %% So, we try to re-add here before normalizing.
    % RawPhone.
    E164Phone = mod_libphonenumber:prepend_plus(RawPhone),
    case mod_libphonenumber:normalize(E164Phone, <<"US">>) of
        undefined ->
            %% We dont expect to hit this error that often as of now.
            %% TODO: update after observing this in release.
            ?ERROR("Invalid raw_phone:~p", [RawPhone]),
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

-spec delete_client_ip(IP :: list(), CC :: binary()) -> boolean().
delete_client_ip(IP, CC) ->
    case is_country_blockable(CC) of
        true -> model_ip_addresses:delete_ip_address(IP, CC);
        false -> ok
    end.


-spec is_ip_blocked(IP :: list(), CC :: binary()) -> false | {true, integer()}.
is_ip_blocked(IP, CC) ->
    case is_country_blockable(CC) of
        false ->
            false;
        true ->
            CurrentTs = util:now(),
            {ok, {Count, LastTs}} = model_ip_addresses:get_ip_address_info(IP, CC),
            IsIpBlocked = case {Count, LastTs} of
                {undefined, _} ->
                    false;
                {_, undefined} ->
                    false;
                {_, _} ->
                    NextTs = util_sms:good_next_ts_diff(Count) + LastTs,
                    case NextTs > CurrentTs of
                        true -> {true, NextTs - CurrentTs};
                        false -> false
                    end
            end,
            case IsIpBlocked of
                false ->
                      ok = model_ip_addresses:add_ip_address(IP, CC, CurrentTs),
                      false;
                {true, _} = Error ->
                      Error
            end
    end.

-spec is_country_blockable(CC :: binary()) -> boolean().
is_country_blockable(CC) ->
    case CC of
        <<"KG">> -> true;  % Kyrgyzstan, 996
        <<"LY">> -> true;  % Libya, 218
        <<"LK">> -> true;  % Sri Lanka, 94
        <<"MR">> -> true;  % Mauritania, 222
        <<"MD">> -> true;  % Maldova, 373
        <<"NG">> -> true;  % Nigeria, 234
        <<"RU">> -> true;  % Russia, 7
        <<"SN">> -> true;  % Senegal, 221
        <<"TW">> -> true;  % Taiwan, 886
        <<"UA">> -> true;  % Ukraine, 380
        <<"UZ">> -> true;  % Uzbekistan, 998
        _ -> false
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

-spec process_whisper_keys(Uid :: uid(), Payload :: map()) -> ok. % | or exception
process_whisper_keys(Uid, Payload) ->
    % check if client is passing identity_key and the other whisper keys,
    % this is optional for now will be mandatory later
    case maps:is_key(<<"identity_key">>, Payload) of
        true ->
            ?INFO("setting keys Uid: ~s", [Uid]),
            {IdentityKey, SignedKey, OneTimeKeys} = get_and_check_whisper_keys(Payload),
            ok = mod_whisper:set_keys_and_notify(Uid, IdentityKey, SignedKey, OneTimeKeys);
        false ->
            ok
    end.

-spec get_and_check_whisper_keys(Payload :: map()) -> {binary(), binary(), [binary()]}.
get_and_check_whisper_keys(Payload) ->
    IdentityKeyB64 = maps:get(<<"identity_key">>, Payload),
    SignedKeyB64 = maps:get(<<"signed_key">>, Payload),
    OneTimeKeysB64 = maps:get(<<"one_time_keys">>, Payload),
    case mod_whisper:check_whisper_keys(IdentityKeyB64, SignedKeyB64, OneTimeKeysB64) of
        {error, Reason} -> error({wk_error, Reason});
        ok -> {IdentityKeyB64, SignedKeyB64, OneTimeKeysB64}
    end.

-spec update_key(binary(), binary()) -> {ok, binary(), binary()}.
update_key(Uid, SPub) ->
    stat:count("HA/account", "update_s_pub"),
    model_auth:set_spub(Uid, SPub).


-spec process_push_token(Uid :: uid(), Payload :: map()) -> ok.
process_push_token(Uid, Payload) ->
    LangId = maps:get(<<"lang_id">>, Payload, <<"en-US">>),
    PushToken = maps:get(<<"push_token">>, Payload, undefined),
    PushOs = maps:get(<<"push_os">>, Payload, undefined),
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
