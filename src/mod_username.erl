%%%----------------------------------------------------------------------
%%% File    : mod_username.erl
%%%
%%% Copyright (C) 2022 HalloApp Inc.
%%%
%%% This file manages usernames.
%%%----------------------------------------------------------------------

-module(mod_username).
-author('vipin').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").
-define(MIN_USERNAME_LEN, 3).
-define(MAX_USERNAME_LEN, 25).

%% gen_mod callbacks.
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

%% hooks and api.
-export([
    process_local_iq/1,
    is_valid_username/1
]).


%%====================================================================
%% gen_mod api
%%====================================================================

start(_Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    gen_iq_handler:add_iq_handler(ejabberd_local, katchup, pb_username_request, ?MODULE, process_local_iq),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_iq_handler:remove_iq_handler(ejabberd_local, katchup, pb_username_request),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% iq handlers and api
%%====================================================================

process_local_iq(
    #pb_iq{from_uid = Uid, type = get, payload = #pb_username_request{
        action = is_available, username = Username}} = IQ) ->
    stat:count("KA/username", "is_available"),
    Result = case model_accounts:is_username_available(Username) of
        true -> ok;
        false -> notuniq
    end,
    ?INFO("Uid: ~p, is_available username ~p, result: ~p", [Uid, Username, Result]),
    case Result of
        ok -> pb:make_iq_result(IQ, #pb_username_response{result = Result});
        _ -> pb:make_iq_result(IQ, #pb_username_response{result = fail, reason = Result})
    end;
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_username_request{action = set, username = Username}} = IQ) ->
    ?INFO("Uid: ~p, set username ~p", [Uid, Username]),
    stat:count("KA/username", "set"),
    Result = case is_valid_username(Username) of
        {false, Err} -> {fail, Err};
        true ->
            case model_accounts:set_username(Uid, Username) of
                {false, Err1} -> {fail, Err1};
                true -> ok
            end
    end,
    case Result of
        ok ->
            AppType = util_uid:get_app_type(Uid),
            ejabberd_hooks:run(username_updated, AppType, [Uid, Username]),
            pb:make_iq_result(IQ, #pb_username_response{result = ok});
        {fail, Err2} ->
            pb:make_iq_result(IQ, #pb_username_response{result = fail, reason = Err2})
    end.
            
-spec is_valid_username(Username :: binary()) -> true | {false, any()}.
is_valid_username(undefined) ->
    {false, tooshort};
is_valid_username(Username) when byte_size(Username) < ?MIN_USERNAME_LEN ->
    {false, tooshort};
is_valid_username(Username) when byte_size(Username) > ?MAX_USERNAME_LEN ->
    {false, toolong};
is_valid_username(Username) ->
    case re:run(Username, "^[a-z][a-z0-9._]*$") of
        nomatch -> {false, badexpr};
        {match, _} -> true
    end.


