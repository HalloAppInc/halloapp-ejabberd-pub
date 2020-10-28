%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, HalloApp, Inc.
%%% @doc
%%% HTTP exporter for prometheus data
%%% @end
%%% Created : 30. Mar 2020 11:42 AM
%%%-------------------------------------------------------------------
-module(mod_prom_exporter).
-author("nikola").
-behaviour(gen_mod).

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").

%% API
-export([start/2, stop/1, reload/3, init/1, depends/2, mod_options/1]).
-export([process/2]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
process([],
        #request{method = 'GET', data = _Data, ip = _IP, headers = _Headers}) ->
    ErlangData = prometheus_text_format:format(),
    HACustomData = stat:get_prometheus_metrics(),
    FinalResponse = <<HACustomData/binary, ErlangData/binary>>,
    ?DEBUG("Response size: ~p", [byte_size(FinalResponse)]),
    {200, ?HEADER(?CT_PLAIN), FinalResponse};

process([<<"_ok">>], _Request) ->
    {200, ?HEADER(?CT_PLAIN), <<"ok">>};

process(Path, Request) ->
    ?WARNING("Bad Request: path: ~p, r:~p", [Path, Request]),
    {404, ?HEADER(?CT_PLAIN), "Not Found"}.


start(Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    application:ensure_started(prometheus),
    gen_mod:start_child(?MODULE, Host, Opts).

stop(Host) ->
    ?INFO("stop ~w", [?MODULE]),
    gen_mod:stop_child(?MODULE, Host).

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

init(_Stuff) ->
    ?INFO("~w init ~p", [?MODULE, _Stuff]),
    process_flag(trap_exit, true),
    {ok, {}}.

-spec mod_options(binary()) -> [{atom(), term()}].
mod_options(_Host) ->
    [].

