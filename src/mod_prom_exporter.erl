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
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([process/2]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
process([],
        #request{method = 'GET', data = _Data, ip = _IP, headers = _Headers}) ->
    ErlangData = prometheus_text_format:format(),
    ?DEBUG("Response size: ~p", [byte_size(ErlangData)]),
    {200, ?HEADER(?CT_PLAIN), ErlangData};

process([<<"_ok">>], _Request) ->
    {200, ?HEADER(?CT_PLAIN), <<"ok">>};

process(Path, Request) ->
    ?WARNING("Bad Request: path: ~p, r:~p", [Path, Request]),
    {404, ?HEADER(?CT_PLAIN), "Not Found"}.


start(_Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    application:ensure_started(prometheus),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

-spec mod_options(binary()) -> [{atom(), term()}].
mod_options(_Host) ->
    [].

