%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%% Created : 10. Jun 2020 10:00 AM
%%%-------------------------------------------------------------------
-module(mod_groups_api).
-author("nikola").
-behaviour(gen_mod).

%% gen_mod api
-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

-export([
    process_local_iq/1
]).

-include("logger.hrl").
-include("xmpp.hrl").
-include("groups.hrl").


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   gen_mod API                                                                              %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


start(Host, _Opts) ->
    ?INFO_MSG("start", []),
    gen_iq_handler:add_iq_handler(ejabberd_local, Host, ?NS_TIME, ?MODULE, process_local_iq),
    ok.


stop(Host) ->
    ?INFO_MSG("stop", []),
    gen_iq_handler:remove_iq_handler(ejabberd_local, Host, ?NS_TIME),
    ok.


reload(_Host, _NewOpts, _OldOpts) ->
    ok.


depends(_Host, _Opts) ->
    [{mod_groups, hard}].


mod_options(_Host) ->
    [].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   API                                                                                      %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


process_local_iq(#iq{} = _IQ) ->
    ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%   Internal                                                                                 %%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%-spec process_local_iq(iq()) -> iq().
%%process_local_iq(#iq{type = set, lang = Lang} = IQ) ->
%%    Txt = ?T("Value 'set' of 'type' attribute is not allowed"),
%%    xmpp:make_error(IQ, xmpp:err_not_allowed(Txt, Lang));
%%process_local_iq(#iq{type = get} = IQ) ->
%%    Now = erlang:timestamp(),
%%    Now_universal = calendar:now_to_universal_time(Now),
%%    Now_local = calendar:universal_time_to_local_time(Now_universal),
%%    Seconds_diff =
%%	calendar:datetime_to_gregorian_seconds(Now_local) -
%%	calendar:datetime_to_gregorian_seconds(Now_universal),
%%    {Hd, Md, _} = calendar:seconds_to_time(abs(Seconds_diff)),
%%    xmpp:make_iq_result(IQ, #time{tzo = {Hd, Md}, utc = Now}).

