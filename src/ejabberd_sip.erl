%%%-------------------------------------------------------------------
%%% File    : ejabberd_sip.erl
%%% Author  : Evgeny Khramtsov <ekhramtsov@process-one.net>
%%% Purpose : 
%%% Created : 30 Apr 2017 by Evgeny Khramtsov <ekhramtsov@process-one.net>
%%%
%%%
%%% ejabberd, Copyright (C) 2013-2018   ProcessOne
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
%%% You should have received a copy of the GNU General Public License along
%%% with this program; if not, write to the Free Software Foundation, Inc.,
%%% 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
%%%
%%%-------------------------------------------------------------------

-module(ejabberd_sip).
-behaviour(ejabberd_listener).

-ifndef(SIP).
-include("logger.hrl").
-export([accept/1, start/2, start_link/2, listen_opt_type/1]).
log_error() ->
    ?CRITICAL_MSG("ejabberd is not compiled with SIP support", []).
accept(_) ->
    log_error(),
    ok.
listen_opt_type(_) ->
    log_error(),
    [].
start(_, _) ->
    log_error(),
    {error, sip_not_compiled}.
start_link(_, _) ->
    log_error(),
    {error, sip_not_compiled}.
-else.
%% API
-export([tcp_init/2, udp_init/2, udp_recv/5, start/2,
	 start_link/2, accept/1, listen_opt_type/1]).


%%%===================================================================
%%% API
%%%===================================================================
tcp_init(Socket, Opts) ->
    ejabberd:start_app(esip),
    esip_socket:tcp_init(Socket, set_certfile(Opts)).

udp_init(Socket, Opts) ->
    ejabberd:start_app(esip),
    esip_socket:udp_init(Socket, Opts).

udp_recv(Sock, Addr, Port, Data, Opts) ->
    esip_socket:udp_recv(Sock, Addr, Port, Data, Opts).

start(Opaque, Opts) ->
    esip_socket:start(Opaque, Opts).

start_link({gen_tcp, Sock}, Opts) ->
    esip_socket:start_link(Sock, Opts).

accept(_) ->
    ok.

set_certfile(Opts) ->
    case lists:keymember(certfile, 1, Opts) of
	true ->
	    Opts;
	false ->
	    case ejabberd_pkix:get_certfile(ejabberd_config:get_myname()) of
		{ok, CertFile} ->
		    [{certfile, CertFile}|Opts];
		error ->
		    case ejabberd_config:get_option({domain_certfile, ejabberd_config:get_myname()}) of
			undefined ->
			    Opts;
			CertFile ->
			    [{certfile, CertFile}|Opts]
		    end
	    end
    end.

listen_opt_type(certfile) ->
    fun(S) ->
	    %% We cannot deprecate the option for now:
	    %% I think SIP clients are too stupid to set SNI
	    ejabberd_pkix:add_certfile(S),
	    iolist_to_binary(S)
    end;
listen_opt_type(tls) ->
    fun(B) when is_boolean(B) -> B end;
listen_opt_type(accept_interval) ->
    fun(I) when is_integer(I), I>=0 -> I end;
listen_opt_type(_) ->
    [tls, certfile, accept_interval].

%%%===================================================================
%%% Internal functions
%%%===================================================================
-endif.
