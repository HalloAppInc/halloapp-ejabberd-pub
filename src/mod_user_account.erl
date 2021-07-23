%%%-----------------------------------------------------------------------------------
%%% File    : mod_user_account.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%%
%%%-----------------------------------------------------------------------------------

-module(mod_user_account).
-author('murali').
-behaviour(gen_mod).

-include("logger.hrl").
-include("packets.hrl").
-include("ejabberd_sm.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% iq handler and API.
-export([
    process_local_iq/1
]).


%%====================================================================
%% gen_mod API.
%%====================================================================

start(Host, _Opts) ->
    ?INFO("start", []),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, pb_delete_account, ?MODULE, process_local_iq),
    ok.

stop(Host) ->
    ?INFO("stop", []),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, pb_delete_account),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].


%%====================================================================
%% hooks.
%%====================================================================

-spec process_local_iq(IQ :: pb_iq()) -> pb_iq().
%% This phone must be sent with the country code.
process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_delete_account{phone = RawPhone}} = IQ) when RawPhone =/= undefined ->
    Server = util:get_host(),
    ?INFO("Uid: ~s, delete_account iq, raw_phone: ~p", [Uid, RawPhone]),
    NormPhone = mod_libphonenumber:normalize(RawPhone, <<"US">>),
    NormPhoneBin = util:to_binary(NormPhone),
    case model_accounts:get_phone(Uid) of
        {ok, NormPhoneBin} when NormPhoneBin =/= undefined ->
            Platform = case model_accounts:get_client_version(Uid) of
                {ok, Version} ->
                    util_ua:get_client_type(Version);
                {error, missing} -> undefined
            end,
            ok = ejabberd_auth:remove_user(Uid, Server),
            CC = mod_libphonenumber:get_cc(NormPhoneBin),
            stat:count("HA/account", "delete", 1, [{cc, CC}, {platform, Platform}]),
            ResponseIq = pb:make_iq_result(IQ, #pb_delete_account{}),
            ejabberd_router:route(ResponseIq),
            ok = ejabberd_sm:disconnect_removed_user(Uid, Server),
            ignore;
        _ ->
            ?INFO("Uid: ~s, Failed delete_account", [Uid]),
            pb:make_error(IQ, util:err(invalid_phone))
    end;

process_local_iq(#pb_iq{from_uid = Uid, type = set,
        payload = #pb_delete_account{phone = undefined}} = IQ) ->
    ?INFO("Uid: ~s, delete_account iq, raw_phone is undefined", [Uid]),
    pb:make_error(IQ, util:err(invalid_phone));

process_local_iq(#pb_iq{} = IQ) ->
    pb:make_error(IQ, util:err(invalid_request)).


%%====================================================================
%% internal functions.
%%====================================================================
