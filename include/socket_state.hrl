%%%----------------------------------------------------------------------
%%% Record for socket_state.
%%%
%%%----------------------------------------------------------------------
-author('murali').

-ifndef(SOCKET_STATE_HRL).
-define(SOCKET_STATE_HRL, 1).


-type sockmod() :: gen_tcp | fast_tls | enoise | ext_mod().
-type socket() :: inet:socket() | fast_tls:tls_socket() | ha_enoise:noise_socket() | ext_socket().
-type ext_mod() :: module().
-type ext_socket() :: any().
-type endpoint() :: {inet:ip_address(), inet:port_number()}.
-type socket_type() :: tls | noise.

-record(socket_state,
{
    sockmod :: sockmod(),
    socket :: socket(),
    max_stanza_size :: integer(),
    pb_stream :: undefined | binary(),
    shaper = none :: none | p1_shaper:state(),
    sock_peer_name = none :: none | {endpoint(), endpoint()},
    socket_type = undefined :: socket_type() | undefined
}).


-type socket_state() :: #socket_state{}.

-endif.
