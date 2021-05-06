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

-define(MSG_TO_SIGN, <<"HALLO">>).

%% API
-export([start/2, stop/1, reload/3, init/1, depends/2, mod_options/1]).
-export([process/2]).

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

process([<<"registration">>, <<"register">>],
        #request{method = 'POST', data = Data, ip = {IP, _Port}, headers = Headers}) ->
    try
        ClientIP = util_http:get_ip(IP, Headers),
        UserAgent = util_http:get_user_agent(Headers),
        ?INFO("registration request: r:~p ip:~p ua:~s", [Data, ClientIP, UserAgent]),
        Payload = jiffy:decode(Data, [return_maps]),
        Phone = maps:get(<<"phone">>, Payload),
        Code = maps:get(<<"code">>, Payload),
        Name = maps:get(<<"name">>, Payload),

        check_ua(UserAgent),
        check_sms_code(Phone, Code),
        LName = check_name(Name),

        {ok, Phone, Uid, Password} = finish_registration(Phone, LName, UserAgent),
        process_whisper_keys(Uid, Payload),

        ?INFO("registration complete uid:~s, phone:~s", [Uid, Phone]),
        {200, ?HEADER(?CT_JSON),
            jiffy:encode({[
                {uid, Uid},
                {phone, Phone},
                {password, Password},
                {name, LName},
                {result, ok}
            ]})}
    catch
        error : bad_user_agent ->
            ?ERROR("register error: bad_user_agent ~p", [Headers]),
            log_register_error(bad_user_agent),
            util_http:return_400();
        error : invalid_client_version ->
            ?ERROR("register error: invalid_client_version ~p", [Headers]),
            util_http:return_400(invalid_client_version);
        error : wrong_sms_code ->
            ?INFO("register error: code missmatch data:~s", [Data]),
            log_register_error(wrong_sms_code),
            util_http:return_400(wrong_sms_code);
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


%% Newer version of `register` API. Uses spub instead of password.
%% TODO(vipin): Refactor error handling code.
process([<<"registration">>, <<"register2">>],
        #request{method = 'POST', data = Data, ip = {IP, _Port}, headers = Headers}) ->
    try
        ClientIP = util_http:get_ip(IP, Headers),
        UserAgent = util_http:get_user_agent(Headers),
        ?INFO("spub registration request: r:~p ip:~s ua:~s", [Data, ClientIP, UserAgent]),
        Payload = jiffy:decode(Data, [return_maps]),
        Phone = maps:get(<<"phone">>, Payload),
        Code = maps:get(<<"code">>, Payload),
        Name = maps:get(<<"name">>, Payload),
        SEdPub = maps:get(<<"s_ed_pub">>, Payload),
        SignedPhrase = maps:get(<<"signed_phrase">>, Payload),

        check_ua(UserAgent),
        check_sms_code(Phone, Code),
        LName = check_name(Name),

        SEdPubBin = base64:decode(SEdPub),
        check_s_ed_pub_size(SEdPubBin),
        SignedPhraseBin = base64:decode(SignedPhrase),
        check_signed_phrase(SignedPhraseBin, SEdPubBin),

        SPub = base64:encode(enacl:crypto_sign_ed25519_public_to_curve25519(SEdPubBin)),

        {ok, Phone, Uid} = finish_registration_spub(Phone, LName, UserAgent, SPub),
        process_whisper_keys(Uid, Payload),

        ?INFO("registration complete uid:~s, phone:~s", [Uid, Phone]),
        {200, ?HEADER(?CT_JSON),
            jiffy:encode({[
                {uid, Uid},
                {phone, Phone},
                {name, LName},
                {result, ok}
            ]})}
    catch
        % TODO: This code is getting out of hand... Figure out how to simplify the error handling
        error : bad_user_agent ->
            ?ERROR("register error: bad_user_agent ~p", [Headers]),
            log_register_error(bad_user_agent),
            util_http:return_400();
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

process([<<"registration">>, <<"update_key">>],
        #request{method = 'POST', data = Data, ip = {IP, _Port}, headers = Headers}) ->
    try
        ClientIP = util_http:get_ip(IP, Headers),
        UserAgent = util_http:get_user_agent(Headers),
        ?INFO("update_key request: r:~p ip:~s ua:~s", [Data, ClientIP, UserAgent]),
        Payload = jiffy:decode(Data, [return_maps]),
        Uid = maps:get(<<"uid">>, Payload),
        Password = maps:get(<<"password">>, Payload),
        SEdPub = maps:get(<<"s_ed_pub">>, Payload),
        SignedPhrase = maps:get(<<"signed_phrase">>, Payload),

        check_ua(UserAgent),
        check_password(Uid, Password),
        SEdPubBin = base64:decode(SEdPub),
        check_s_ed_pub_size(SEdPubBin),
        SignedPhraseBin = base64:decode(SignedPhrase),
        check_signed_phrase(SignedPhraseBin, SEdPubBin),

        SPub = base64:encode(enacl:crypto_sign_ed25519_public_to_curve25519(SEdPubBin)),
        ok = update_key(Uid, SPub),
        ?INFO("update key complete uid:~s", [Uid]),
        {200, ?HEADER(?CT_JSON), jiffy:encode({[{result, ok}]})}
    catch
        error : bad_user_agent ->
            ?ERROR("register error: bad_user_agent ~p", [Headers]),
            util_http:return_400();
        error : invalid_client_version ->
            ?ERROR("register error: invalid_client_version ~p", [Headers]),
            util_http:return_400(invalid_client_version);
        error : invalid_password ->
            ?INFO("register error: invalid password, data:~s", [Data]),
            util_http:return_400(invalid_password);
        error : invalid_s_ed_pub ->
            ?ERROR("register error: invalid_s_ed_pub ~p", [Data]),
            util_http:return_400(invalid_s_ed_pub);
        error : invalid_signed_phrase ->
            ?ERROR("register error: invalid_signed_phrase ~p", [Data]),
            util_http:return_400(invalid_signed_phrase);
        error : unable_to_open_signed_phrase ->
            ?ERROR("register error: unable_to_open_signed_phrase ~p", [Data]),
            util_http:return_400(unable_to_open_signed_phrase);
        error: {badkey, <<"uid">>} ->
            util_http:return_400(missing_uid);
        error: {badkey, <<"password">>} ->
            util_http:return_400(missing_password);
        error: {badkey, <<"s_ed_pub">>} ->
            util_http:return_400(missing_s_ed_pub);
        error: {badkey, <<"signed_phrase">>} ->
            util_http:return_400(missing_signed_phrase);
        error : Reason : Stacktrace  ->
            ?ERROR("update key error: ~p, ~p", [Reason, Stacktrace]),
            util_http:return_500()
    end;

process([<<"_ok">>], _Request) ->
    {200, ?HEADER(?CT_PLAIN), <<"ok">>};
process(Path, Request) ->
    ?WARNING("Bad Request: path: ~p, r:~p", [Path, Request]),
    util_http:return_400().

-spec process_otp_request(Data :: string(), IP :: string(), Headers :: list(),
    MethodInRequest :: boolean()) -> http_response().
process_otp_request(Data, IP, Headers, MethodInRequest) ->
    try
        ?DEBUG("Data:~p", [Data]),
        UserAgent = util_http:get_user_agent(Headers),
        ClientIP = util_http:get_ip(IP, Headers),
        Payload = jiffy:decode(Data, [return_maps]),
        Phone = maps:get(<<"phone">>, Payload),
        Method = case MethodInRequest of
            false -> <<"sms">>;
            _ -> maps:get(<<"method">>, Payload, <<"sms">>)
        end,
        LanguageId = maps:get(<<"lang_id">>, Payload, <<"en-US">>),
        GroupInviteToken = maps:get(<<"group_invite_token">>, Payload, undefined),
        ?INFO("phone:~p, ua:~p ip:~s method: ~s, language: ~p, payload:~p ",
            [Phone, UserAgent, ClientIP, Method, LanguageId, Payload]),

        check_ua(UserAgent),
        Method2 = get_otp_method(Method),
        check_invited(Phone, UserAgent, ClientIP, GroupInviteToken),
        request_otp(Phone, UserAgent, Method2),
        {200, ?HEADER(?CT_JSON),
            jiffy:encode({[
                {phone, Phone},
                {retry_after_secs, ?SMS_RETRY_AFTER_SECS},
                {result, ok}
            ]})}
    catch
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
        error : voice_call_fail ->
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


-spec request_otp(Phone :: phone(), UserAgent :: binary(), Method :: atom()) -> ok | no_return(). % throws otp_fail
request_otp(Phone, UserAgent, Method) ->
    case mod_sms:request_otp(Phone, UserAgent, Method) of
        ok -> ok;
        {error, Reason} = Error->
            ?ERROR("could not send otp Reason: ~p Phone: ~P", [Reason, Phone]),
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

-spec check_password(binary(), binary()) -> ok.
check_password(Uid, Password) ->
    case ejabberd_auth:check_password(Uid, Password) of
        true -> ok;
        false ->
            ?ERROR("Invalid Password for Uid:~p", [Uid]),
            error(invalid_password)
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


-spec check_invited(PhoneNum :: binary(), UserAgent :: binary(), IP :: string(),
        GroupInviteToken :: binary()) -> ok | erlang:error().
check_invited(PhoneNum, UserAgent, IP, GroupInviteToken) ->
    Invited = model_invites:is_invited(PhoneNum),
    IsTestNumber = util:is_test_number(PhoneNum),
    IsInvitedToGroup = is_group_invite_valid(GroupInviteToken),
    IsAllowedVersion = is_version_invite_opened(UserAgent),
    IsIPAllowed = is_ip_invite_opened(IP),
    IsCCAllowed = is_cc_invite_opened(PhoneNum),
    case Invited orelse IsTestNumber orelse IsInvitedToGroup orelse IsAllowedVersion orelse
            IsIPAllowed orelse IsCCAllowed of
        true -> ok;
        false ->
            case model_phone:get_uid(PhoneNum) of
                {ok, undefined} ->
                    log_not_invited(PhoneNum),

                    erlang:error(not_invited);
                {ok, _Uid} ->
                    ok
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

-spec finish_registration(phone(), binary(), binary()) -> {ok, phone(), binary(), binary()}.
finish_registration(Phone, Name, UserAgent) ->
    Password = util:generate_password(),
    Host = util:get_host(),
    {ok, Uid, Action} = ejabberd_admin:check_and_register(Phone, Host, Password, Name, UserAgent),
    %% Action = login, updates the password.
    %% Action = register, creates a new user id and registers the user for the first time.
    log_registration(Action, UserAgent),
    {ok, Phone, Uid, Password}.

-spec finish_registration_spub(phone(), binary(), binary(), binary()) -> {ok, phone(), binary()}.
finish_registration_spub(Phone, Name, UserAgent, SPub) ->
    Host = util:get_host(),
    {ok, Uid, Action} = ejabberd_admin:check_and_register_spub(Phone, Host, SPub, Name, UserAgent),
    %% Action = login, updates the password.
    %% Action = register, creates a new user id and registers the user for the first time.
    log_registration(Action, UserAgent),
    {ok, Phone, Uid}.

log_registration(Action, UserAgent) ->
    case Action of
        login ->
            stat:count("HA/account", "login_by_client_type", 1,
                [{client_type, util_ua:get_client_type(UserAgent)}]);
        register ->
            stat:count("HA/account", "registration_by_client_type", 1,
                [{client_type, util_ua:get_client_type(UserAgent)}])
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


start(Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_mod:stop_child(?MODULE, Host).

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [{mod_sms, hard}].

init(_Stuff) ->
    ?INFO("mod_halloapp_http_api init ~p", [_Stuff]),
    {ok, {}}.

-spec mod_options(binary()) -> [{atom(), term()}].
mod_options(_Host) ->
    [].
