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
-include("xmpp.hrl").
-include("ejabberd_http.hrl").
-include("bosh.hrl").
-include("account.hrl").
-include("ha_types.hrl").

-define(MSG_TO_SIGN, <<"HALLO">>).

%% API
-export([start/2, stop/1, reload/3, init/1, depends/2, mod_options/1]).
-export([process/2]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------
-type http_response_code() :: integer().
-type http_header() :: {binary(), binary()}.
-type http_headers() :: [http_header()].
-type http_body() :: binary().
-type http_response() :: {http_response_code(), http_headers(), http_body()}.
-type http_path() :: [binary()].


-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
process([<<"registration">>, <<"request_sms">>],
        #request{method = 'POST', data = Data, ip = IP, headers = Headers}) ->
    try
        ?DEBUG("Data:~p", [Data]),
        UserAgent = get_user_agent(Headers),
        Payload = jiffy:decode(Data, [return_maps]),
        Phone = maps:get(<<"phone">>, Payload),
        ?INFO_MSG("payload ~p phone:~p, ua:~p ip:~p ~p",
            [Payload, Phone, UserAgent, IP, util:is_test_number(Phone)]),

        check_invited(Phone),
        check_ua(UserAgent),
        request_sms(Phone, UserAgent),
        {200, ?HEADER(?CT_JSON),
            jiffy:encode({[
                {phone, Phone},
                {result, ok}
            ]})}
    catch
        error : bad_user_agent ->
            ?ERROR_MSG("register error: bad_user_agent ~p", [Headers]),
            return_400();
        error: not_invited ->
            ?INFO_MSG("request_sms error: phone not invited ~p", [Data]),
            return_400(not_invited);
        error : sms_fail ->
            ?INFO_MSG("request_sms error: sms_failed ~p", [Data]),
            return_400(sms_fail);
        Class : Reason : Stacktrace  ->
            ?ERROR_MSG("request_sms crash: ~s\nStacktrace:~s",
                [Reason, lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            return_500()
    end;

process([<<"registration">>, <<"register">>],
        #request{method = 'POST', data = Data, ip = IP, headers = Headers}) ->
    try
        ?INFO_MSG("registration request: r:~p ip:~p", [Data, IP]),
        UserAgent = get_user_agent(Headers),
        Payload = jiffy:decode(Data, [return_maps]),
        Phone = maps:get(<<"phone">>, Payload),
        Code = maps:get(<<"code">>, Payload),
        Name = maps:get(<<"name">>, Payload),

        check_ua(UserAgent),
        check_sms_code(Phone, Code),
        LName = check_name(Name),
        {ok, Phone, Uid, Password} = finish_registration(Phone, LName, UserAgent),
        ?INFO_MSG("registration complete uid:~s, phone:~s", [Uid, Phone]),
        {200, ?HEADER(?CT_JSON),
            jiffy:encode({[
                {uid, Uid},
                {phone, Phone},
                {password, Password},
                {name, LName},
                {result, ok}
            ]})}
    catch
        error : wrong_sms_code ->
            ?INFO_MSG("register error: code missmatch data:~s", [Data]),
            return_400(wrong_sms_code);
        error : bad_user_agent ->
            ?ERROR_MSG("register error: bad_user_agent ~p", [Headers]),
            return_400();
        error: {badkey, <<"phone">>} ->
            return_400(missing_phone);
        error: {badkey, <<"code">>} ->
            return_400(missing_code);
        error: {badkey, <<"name">>} ->
            return_400(missing_name);
        error: invalid_name ->
            return_400(invalid_name);
        error : Reason : Stacktrace  ->
            ?ERROR_MSG("register error: ~p, ~p", [Reason, Stacktrace]),
            return_500()
    end;


%% Newer version of `register` API. Uses spub instead of password.
%% TODO(vipin): Refactor error handling code.
process([<<"registration">>, <<"register2">>],
        #request{method = 'POST', data = Data, ip = IP, headers = Headers}) ->
    try
        ?INFO_MSG("spub registration request: r:~p ip:~p", [Data, IP]),
        UserAgent = get_user_agent(Headers),
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
        ?INFO_MSG("registration complete uid:~s, phone:~s", [Uid, Phone]),
        {200, ?HEADER(?CT_JSON),
            jiffy:encode({[
                {uid, Uid},
                {phone, Phone},
                {name, LName},
                {result, ok}
            ]})}
    catch
        error : wrong_sms_code ->
            ?INFO_MSG("register error: code mismatch data:~s", [Data]),
            return_400(wrong_sms_code);
        error : bad_user_agent ->
            ?ERROR_MSG("register error: bad_user_agent ~p", [Headers]),
            return_400();
        error : invalid_s_ed_pub ->
            ?ERROR_MSG("register error: invalid_s_ed_pub ~p", [Data]),
            return_400(invalid_s_ed_pub);
        error : invalid_signed_phrase ->
            ?ERROR_MSG("register error: invalid_signed_phrase ~p", [Data]),
            return_400(invalid_signed_phrase);
        error : unable_to_open_signed_phrase ->
            ?ERROR_MSG("register error: unable_to_open_signed_phrase ~p", [Data]),
            return_400(unable_to_open_signed_phrase);
         error: {badkey, <<"phone">>} ->
            return_400(missing_phone);
        error: {badkey, <<"code">>} ->
            return_400(missing_code);
        error: {badkey, <<"name">>} ->
            return_400(missing_name);
        error: {badkey, <<"s_ed_pub">>} ->
            return_400(missing_s_ed_pub);
        error: {badkey, <<"signed_phrase">>} ->
            return_400(missing_signed_phrase);
        error: invalid_name ->
            return_400(invalid_name);
        error : Reason : Stacktrace  ->
            ?ERROR_MSG("register error: ~p, ~p", [Reason, Stacktrace]),
            return_500()
    end;

process([<<"registration">>, <<"update_key">>],
        #request{method = 'POST', data = Data, ip = IP, headers = Headers}) ->
    try
        ?INFO_MSG("update_key request: r:~p ip:~p", [Data, IP]),
        UserAgent = get_user_agent(Headers),
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
        ?INFO_MSG("update key complete uid:~s", [Uid]),
        {200, ?HEADER(?CT_JSON), jiffy:encode({[{result, ok}]})}
    catch
        error : bad_user_agent ->
            ?ERROR_MSG("register error: bad_user_agent ~p", [Headers]),
            return_400();
        error : invalid_password ->
            ?INFO_MSG("register error: invalid password, data:~s", [Data]),
            return_400(invalid_password);
        error : invalid_s_ed_pub ->
            ?ERROR_MSG("register error: invalid_s_ed_pub ~p", [Data]),
            return_400(invalid_s_ed_pub);
        error : invalid_signed_phrase ->
            ?ERROR_MSG("register error: invalid_signed_phrase ~p", [Data]),
            return_400(invalid_signed_phrase);
        error : unable_to_open_signed_phrase ->
            ?ERROR_MSG("register error: unable_to_open_signed_phrase ~p", [Data]),
            return_400(unable_to_open_signed_phrase);
        error: {badkey, <<"uid">>} ->
            return_400(missing_uid);
        error: {badkey, <<"password">>} ->
            return_400(missing_password);
        error: {badkey, <<"s_ed_pub">>} ->
            return_400(missing_s_ed_pub);
        error: {badkey, <<"signed_phrase">>} ->
            return_400(missing_signed_phrase);
        error : Reason : Stacktrace  ->
            ?ERROR_MSG("update key error: ~p, ~p", [Reason, Stacktrace]),
            return_500()
    end;

process([<<"_ok">>], _Request) ->
    {200, ?HEADER(?CT_PLAIN), <<"ok">>};
process(Path, Request) ->
    ?WARNING_MSG("Bad Request: path: ~p, r:~p", [Path, Request]),
    return_400().


-spec check_ua(binary()) -> ok | no_return().
check_ua(UserAgent) ->
    case util_ua:is_hallo_ua(UserAgent) of
        true -> ok;
        false ->
            ?ERROR_MSG("Invalid UserAgent:~p", [UserAgent]),
            error(bad_user_agent)
    end.


-spec check_password(binary(), binary()) -> ok.
check_password(Uid, Password) ->
    case ejabberd_auth:check_password(Uid, Password) of
        true -> ok;
        false ->
            ?ERROR_MSG("Invalid Password for Uid:~p", [Uid]),
            error(invalid_password)
    end.

-spec check_s_ed_pub_size(SEdPub :: binary()) -> ok | error.
check_s_ed_pub_size(SEdPub) ->
    case byte_size(SEdPub) of
        32 -> ok;
        _ ->
            ?ERROR_MSG("Invalid s_ed_pub: ~p", [SEdPub]),
            error(invalid_s_ed_pub)
    end.

-spec check_signed_phrase(SignedPhrase :: binary(), SEdPub:: binary())  -> ok | error.
check_signed_phrase(SignedPhrase, SEdPub) ->
    case enacl:sign_open(SignedPhrase, SEdPub) of
        {ok, ?MSG_TO_SIGN} -> ok;
        {ok, Phrase} ->
            ?ERROR_MSG("Invalid Signed Phrase: ~p", [Phrase]),
            error(invalid_signed_phrase);
        {error, _} ->
            ?ERROR_MSG("Unable to open signed message: ~p", [base64:encode(SignedPhrase)]),
            error(unable_to_open_signed_phrase)
    end.


-spec check_name(Name :: binary()) -> binary() | any().
check_name(<<"">>) ->
    error(invalid_name);
check_name(Name) when is_binary(Name) ->
    LName = string:slice(Name, 0, ?MAX_NAME_SIZE),
    case LName =:= Name of
        false ->
            ?WARNING_MSG("Truncating user name to |~s| size was: ~p", [LName, byte_size(Name)]);
        true ->
            ok
    end,
    LName;
check_name(_) ->
    error(invalid_name).


-spec check_invited(PhoneNum :: binary()) -> ok | erlang:error().
check_invited(PhoneNum) ->
    Invited = model_invites:is_invited(PhoneNum),
    case Invited of
        true -> ok;
        false ->
            case model_phone:get_uid(PhoneNum) of
                {ok, undefined} -> erlang:error(not_invited);
                {ok, _Uid} -> ok
            end
    end.


-spec update_key(binary(), binary()) -> {ok, binary(), binary()}.
update_key(Uid, SPub) ->
    stat:count("HA/account", "update_s_pub"),
    model_auth:set_spub(Uid, SPub).

-spec finish_registration(phone(), binary(), binary()) -> {ok, phone(), binary(), binary()}.
finish_registration(Phone, Name, UserAgent) ->
    Password = util:generate_password(),
    Host = util:get_host(),
    {ok, Uid, _Action} = ejabberd_admin:check_and_register(Phone, Host, Password, Name, UserAgent),
    %% Action = login, updates the password.
    %% Action = register, creates a new user id and registers the user for the first time.
    %% Note: We don't need to clear the push token in either of login/register case. 
    stat:count_d("HA/account", "registration_by_client_type",
        [{client_type, util_ua:get_client_type(UserAgent)}]),
    {ok, Phone, Uid, Password}.

-spec finish_registration_spub(phone(), binary(), binary(), binary()) -> {ok, phone(), binary()}.
finish_registration_spub(Phone, Name, UserAgent, SPub) ->
    Host = util:get_host(),
    {ok, Uid, _Action} = ejabberd_admin:check_and_register_spub(Phone, Host, SPub, Name, UserAgent),
    %% Action = login, updates the password.
    %% Action = register, creates a new user id and registers the user for the first time.
    %% Note: We don't need to clear the push token in either of login/register case. 
    stat:count_d("HA/account", "registration_by_client_type",
        [{client_type, util_ua:get_client_type(UserAgent)}]),
    {ok, Phone, Uid}.

%% Throws error if the code is wrong
-spec check_sms_code(phone(), binary()) -> ok.
check_sms_code(Phone, Code) ->
    Host = util:get_host(),
    case {ejabberd_admin:get_user_passcode(Phone, Host), Code} of
        {{ok, MatchingCode}, MatchingCode} when size(MatchingCode) =:= 6 ->
            ?DEBUG("Code match phone:~s code:~s", [Phone, MatchingCode]),
            ok;
        {{ok, StoredCode}, UserCode}->
            ?INFO_MSG("Codes mismatch, phone:~s, StoredCode:~s UserCode:~s",
                [Phone, StoredCode, UserCode]),
            error(wrong_sms_code);
        Any ->
            ?INFO_MSG("No stored code in db ~p", [Any]),
            error(wrong_sms_code)
    end.


-spec request_sms(Phone :: phone(), UserAgent :: binary()) -> ok.
request_sms(Phone, UserAgent) ->
    Code = mod_sms:generate_code(util:is_test_number(Phone)),
    ?DEBUG("code generated phone:~s code:~s", [Phone, Code]),
    finish_enroll(Phone, Code),
    case util:is_test_number(Phone) of
        true -> ok;
        false ->
            {ok, Receipt} = send_sms(Phone, Code, UserAgent),
            model_phone:add_sms_code_receipt(Phone, Receipt)
    end.


-spec send_sms(Phone :: phone(), Code :: binary(), UserAgent :: binary()) ->
        {ok, binary()} | no_return().
send_sms(Phone, Code, UserAgent) ->
    Msg = mod_sms:prepare_registration_sms(Code, UserAgent),
    ?DEBUG("preparing to send sms, phone:~p msg:~s", [Phone, Msg]),
    case mod_sms:send_sms(Phone, Msg) of
        {ok, Receipt} -> {ok, Receipt};
        {error, Error} -> erlang:error(Error)
    end.


-spec finish_enroll(phone(), binary()) -> any().
finish_enroll(Phone, Code) ->
    Host = util:get_host(),
    {ok, _} = ejabberd_admin:unenroll(Phone, Host),
    {ok, _} = ejabberd_admin:enroll(Phone, Host, Code),
    ok.


-spec return_400(term()) -> http_response().
return_400(Error) ->
    ?WARNING_MSG("400 ~p", [Error]),
    {400, ?HEADER(?CT_JSON), jiffy:encode({[
        {result, fail},
        {error, Error}]})}.

-spec return_400() -> http_response().
return_400() ->
    return_400(bad_request).

-spec return_500() -> http_response().
return_500() ->
    {500, ?HEADER(?CT_JSON),
        jiffy:encode({[{result, <<"Internal Server Error">>}]})}.

start(Host, Opts) ->
    ?INFO_MSG("start ~w ~p", [?MODULE, Opts]),
    gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
    ?INFO_MSG("stop ~w", [?MODULE]),
    gen_mod:stop_child(?MODULE, Host).

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

get_user_agent(Hdrs) ->
    {_, S} = lists:keyfind('User-Agent', 1, Hdrs),
    S.

depends(_Host, _Opts) ->
    [{mod_sms, hard}].

init(_Stuff) ->
    ?INFO_MSG("mod_halloapp_http_api init ~p", [_Stuff]),
    process_flag(trap_exit, true),
    {ok, {}}.

-spec mod_options(binary()) -> [{atom(), term()}].
mod_options(_Host) ->
    [].
