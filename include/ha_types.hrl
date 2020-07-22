%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 05. Jun 2020 3:31 PM
%%%-------------------------------------------------------------------
-author("nikola").

-ifndef(HA_TYPES).

-define(HA_TYPES, 1).

-type uid() :: binary().
-type gid() :: binary().

-type names_map() :: #{uid() := binary()}.

-type client_type() :: android | ios.

-type pname() :: atom().
-type pvalue() :: binary() | boolean() | float() | integer() | float().
-type property() :: {pname(), pvalue()}.
-type proplist() :: [property()].

-endif.

