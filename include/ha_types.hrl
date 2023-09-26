%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%
%%% @end
%%% Created : 05. Jun 2020 3:31 PM
%%%-------------------------------------------------------------------

-ifndef(HA_TYPES).
-define(HA_TYPES, 1).

-type maybe(T) :: T | undefined.

-type uid() :: binary().
-type gid() :: binary().
-type call_id() :: binary().

-type phone() :: binary().

-type names_map() :: #{uid() := binary()}.

-type client_type() :: android | ios.
-type app_type() :: halloapp | katchup.

-type pname() :: atom().
-type pvalue() :: binary() | boolean() | float() | integer().
-type property() :: {pname(), pvalue()}.
-type proplist() :: [property()].

% TODO(nikola): it would make more sense if we just use unix timestamp instead of erlang:timestamp()
-type sid() :: {timestamp(), pid()}.
-type timestamp() :: erlang:timestamp().

-type mode() :: active | passive.

-define(HALLOAPP, halloapp).
-define(KATCHUP, katchup).

-type(avatar_id() :: binary()).

-endif.

