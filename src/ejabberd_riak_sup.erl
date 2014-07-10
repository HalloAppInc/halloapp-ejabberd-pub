%%%----------------------------------------------------------------------
%%% File    : ejabberd_riak_sup.erl
%%% Author  : Alexey Shchepin <alexey@process-one.net>
%%% Purpose : Riak connections supervisor
%%% Created : 29 Dec 2011 by Alexey Shchepin <alexey@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2002-2011   ProcessOne
%%%
%%% This program is free software; you can redistribute it and/or
%%% modify it under the terms of the GNU General Public License as
%%% published by the Free Software Foundation; either version 2 of the
%%% License, or (at your option) any later version.
%%%
%%% This program is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
%%% General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with this program; if not, write to the Free Software
%%% Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA
%%% 02111-1307 USA
%%%
%%%----------------------------------------------------------------------

-module(ejabberd_riak_sup).
-author('alexey@process-one.net').

%% API
-export([start/0,
         start_link/0,
	 init/1,
	 add_pid/1,
	 remove_pid/1,
	 get_pids/0,
	 get_random_pid/0
	]).

-include("ejabberd.hrl").

-define(DEFAULT_POOL_SIZE, 10).
-define(DEFAULT_RIAK_START_INTERVAL, 30). % 30 seconds

% time to wait for the supervisor to start its child before returning
% a timeout error to the request
-define(CONNECT_TIMEOUT, 500). % milliseconds


-record(riak_pool, {undefined, pid}).

start() ->
    StartRiak = ejabberd_config:get_local_option(
                  riak_server, fun(_) -> true end, false),
    if
        StartRiak ->
            do_start();
        true ->
            ok
    end.

do_start() ->
    SupervisorName = ?MODULE,
    ChildSpec =
	{SupervisorName,
	 {?MODULE, start_link, []},
	 transient,
	 infinity,
	 supervisor,
	 [?MODULE]},
    case supervisor:start_child(ejabberd_sup, ChildSpec) of
	{ok, _PID} ->
	    ok;
	_Error ->
	    ?ERROR_MSG("Start of supervisor ~p failed:~n~p~nRetrying...~n",
                       [SupervisorName, _Error]),
            timer:sleep(5000),
	    start()
    end.

start_link() ->
    mnesia:create_table(riak_pool,
			[{ram_copies, [node()]},
			 {type, bag},
			 {local_content, true},
			 {attributes, record_info(fields, riak_pool)}]),
    mnesia:add_table_copy(riak_pool, node(), ram_copies),
    F = fun() ->
		mnesia:delete({riak_pool, undefined})
	end,
    mnesia:ets(F),
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    PoolSize =
        ejabberd_config:get_local_option(
          riak_pool_size,
          fun(N) when is_integer(N), N >= 1 -> N end,
          ?DEFAULT_POOL_SIZE),
    StartInterval =
        ejabberd_config:get_local_option(
          riak_start_interval,
          fun(N) when is_integer(N), N >= 1 -> N end,
          ?DEFAULT_RIAK_START_INTERVAL),
    {Server, Port} =
        ejabberd_config:get_local_option(
          riak_server,
          fun({S, P}) when is_integer(P), P > 0, P < 65536 ->
                  {binary_to_list(iolist_to_binary(S)), P}
          end, {"127.0.0.1", 8081}),
    {ok, {{one_for_one, PoolSize*10, 1},
	  lists:map(
	    fun(I) ->
		    {I,
		     {ejabberd_riak, start_link,
                      [Server, Port, StartInterval*1000]},
		     transient,
                     2000,
		     worker,
		     [?MODULE]}
	    end, lists:seq(1, PoolSize))}}.

get_pids() ->
    Rs = mnesia:dirty_read(riak_pool, undefined),
    [R#riak_pool.pid || R <- Rs].

get_random_pid() ->
    Pids = get_pids(),
    lists:nth(erlang:phash(now(), length(Pids)), Pids).

add_pid(Pid) ->
    F = fun() ->
		mnesia:write(
		  #riak_pool{pid = Pid})
	end,
    mnesia:ets(F).

remove_pid(Pid) ->
    F = fun() ->
		mnesia:delete_object(
		  #riak_pool{pid = Pid})
	end,
    mnesia:ets(F).
