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
-type phone() :: [0..9].

-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
process([<<"registration">>, <<"request_sms">>], Request) ->
    try
        Data = Request#request.data,
        Method = Request#request.method,
        Headers = Request#request.headers,
        ?DEBUG("request_sms ~p Data:~p: r:~p", [Method, Data, Request]),
        UserAgent = get_user_agent(Headers),
        Payload = jiffy:decode(Data, [return_maps]),
        Phone = binary_to_list(maps:get(<<"phone">>, Payload)),
        ?DEBUG("payload ~p phone: ~p, ua: ~p ~p", [Payload, Phone, UserAgent, is_debug(Phone)]),
        case {Method, util_ua:is_hallo_ua(UserAgent)} of
            {'POST', true} -> request_sms(Phone, UserAgent);
            _  -> return_400()
        end
    catch
        _:Error:Stacktrace ->
            ?ERROR_MSG("request_sms error: ~p ~p", [Error, Stacktrace]),
            return_500()
    end;

process([<<"registration">>, <<"register">>],
        #request{method = 'POST', data = Data, ip = IP, headers = Headers}) ->
    try
        ?DEBUG("registration request: r:~p ip:~p", [Data, IP]),
        UserAgent = get_user_agent(Headers),
        Payload = jiffy:decode(Data, [return_maps]),
        %% TODO: check arguments exists
        Phone = binary_to_list(maps:get(<<"phone">>, Payload)),
        Code = binary_to_list(maps:get(<<"code">>, Payload)),
        check_ua(UserAgent),
        check_sms_code(Phone, Code),
        {ok, Phone, Uid, Password} = finish_registration(Phone),
        {200, ?HEADER(?CT_JSON),
            jiffy:encode({[
                {uid, Uid},
                {phone, list_to_binary(Phone)},
                {password, Password},
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
        error : Reason : Stacktrace  ->
            ?ERROR_MSG("register error: ~p, ~p", [Reason, Stacktrace]),
            return_500()
    end;

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

-spec generate_password() -> binary().
generate_password() ->
    P = base64:encode_to_string(crypto:strong_rand_bytes(24)),
    PP = lists:map(fun (C) ->
        case C of
            $+ -> $_;
            $/ -> $-;
            X -> X
        end end, P),
    list_to_binary(PP).

-spec finish_registration(phone()) -> {ok, phone(), binary(), binary()}.
finish_registration(Phone) ->
    Password = generate_password(),
    Host = util:get_host(),
    % TODO: this is templorary during the migration from Phone to Uid
    {ok, _} = ejabberd_admin:unregister_push(Phone, Host),
    {ok, Uid, Action} = ejabberd_admin:check_and_register(Phone, Host, Password),
    case Action of
        login ->
            % Unregister the push token
            ejabberd_admin:unregister_push(Uid, Host);
        register -> ok
    end,
    {ok, Phone, Uid, Password}.

%% Throws error if the code is wrong
-spec check_sms_code(phone(), string()) -> ok.
check_sms_code(Phone, Code) ->
    Host = util:get_host(),
    case {ejabberd_admin:get_user_passcode(Phone, Host), list_to_binary(Code)} of
        {{ok, MatchingCode}, MatchingCode} when size(MatchingCode) =:= 6 ->
            ?DEBUG("Code match phone:~p code:~p",
                [Phone, MatchingCode]),
            ok;
        {{ok, StoredCode}, UserCode}->
            ?INFO_MSG("Codes mismatch, phone:~p, StoredCode:~p UserCode:~p",
                [Phone, StoredCode, UserCode]),
            error(wrong_sms_code);
        Any ->
            ?INFO_MSG("No stored code in db ", [Any]),
            error(wrong_sms_code)
    end.


-spec request_sms(Phone :: phone(), UserAgent :: binary()) -> http_response().
request_sms(Phone, UserAgent) ->
    Code = mod_sms:generate_code(is_debug(Phone)),
    Msg = mod_sms:prepare_registration_sms(Code, UserAgent),
    ?DEBUG("code generated phone:~p : code:~p msg: ~s", [Phone, Code, Msg]),
    EnrollResult = case mod_sms:send_sms(Phone, Msg) of
        ok -> finish_enroll(Phone, Code);
        X -> X
    end,
    case EnrollResult of
        {ok, _Text} ->
            {200, ?HEADER(?CT_JSON), jiffy:encode({[
                {phone, list_to_binary(Phone)},
                {result, ok}]})};
        {error, cannot_enroll, _, Reason} ->
            ?DEBUG("cannot_enroll ~s", [Reason]),
            return_400(cannot_enroll);
        {error, sms_fail} ->
            return_400(sms_fail)
    end.

-spec finish_enroll(phone(), binary()) -> any().
finish_enroll(Phone, Code) ->
    Host = util:get_host(),
    %% This seems to be an security issue.
    ejabberd_admin:unregister_push(Phone, Host),
    ejabberd_admin:unenroll(Phone, Host),
    ejabberd_admin:enroll(Phone, Host, Code).

-spec return_400(term()) -> http_response().
return_400(Error) ->
    ?DEBUG("400 ~p", [Error]),
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

is_debug(Phone) ->
    case re:run(Phone, "^1...555....$") of
        {match, _} -> true;
        _ -> false
    end.

depends(_Host, _Opts) ->
    [{mod_sms, hard}].

init(_Stuff) ->
    ?INFO_MSG("mod_halloapp_http_api init ~p", [_Stuff]),
    process_flag(trap_exit, true),
    {ok, {}}.

-spec mod_options(binary()) -> [{atom(), term()}].
mod_options(_Host) ->
    [].
