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

-include("logger.hrl").
-include("xmpp.hrl").
-include("ejabberd_http.hrl").
-include("bosh.hrl").
-include("account.hrl").

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

% TODO: move this to some header?
-type phone() :: binary().


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

process([<<"_ok">>], _Request) ->
    {200, ?HEADER(?CT_PLAIN), <<"ok">>};
process(Path, Request) ->
    ?WARNING_MSG("Bad Request: path: ~p, r:~p", [Path, Request]),
    return_400().


-spec check_ua(binary()) -> boolean().
check_ua(UserAgent) ->
    case util_ua:is_hallo_ua(UserAgent) of
        true -> ok;
        false ->
            ?ERROR_MSG("Invalid UserAgent:~p", [UserAgent]),
            error(bad_user_agent)
    end.


-spec check_name(Name :: binary()) -> binary() | any().
check_name(<<"">>) ->
    error(invalid_name);
check_name(Name) when is_binary(Name) ->
    LName = string:slice(Name, 0, ?MAX_NAME_SIZE),
    case LName =:= Name of
        false ->
            ?WARNING_MSG("Truncating user name to |~s| size was: ~p", [LName, length(Name)]);
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


-spec finish_registration(phone(), binary(), binary()) -> {ok, phone(), binary(), binary()}.
finish_registration(Phone, Name, UserAgent) ->
    Password = util:generate_password(),
    Host = util:get_host(),
    % TODO: this is templorary during the migration from Phone to Uid
    {ok, _} = ejabberd_admin:unregister_push(Phone, Host),
    {ok, Uid, Action} = ejabberd_admin:check_and_register(Phone, Host, Password, Name, UserAgent),
    case Action of
        login ->
            % Unregister the push token
            ejabberd_admin:unregister_push(Uid, Host);
        register -> ok
    end,
    stat:count_d("HA/account", "registration_by_client_type",
        [{client_type, util_ua:get_client_type(UserAgent)}]),
    {ok, Phone, Uid, Password}.

%% Throws error if the code is wrong
-spec check_sms_code(phone(), string()) -> ok.
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
    case util:is_test_number(Phone) of
        true -> ok;
        false ->
            ok = send_sms(Phone, Code, UserAgent)
    end,
    finish_enroll(Phone, Code).


-spec send_sms(Phone :: phone(), Code :: binary(), UserAgent :: binary()) -> ok.
send_sms(Phone, Code, UserAgent) ->
    Msg = mod_sms:prepare_registration_sms(Code, UserAgent),
    ?DEBUG("preparing to send sms, phone:~p msg:~s", [Phone, Msg]),
    case mod_sms:send_sms(Phone, Msg) of
        ok -> ok;
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
