%%%----------------------------------------------------------------------
%%% File    : util_id.erl
%%%
%%% Copyright (C) 2021 halloappinc.
%%%
%%%----------------------------------------------------------------------

-module(util_id).
-author('murali').
-include("logger.hrl").
-include("xmpp.hrl").
-include("packets.hrl").
-include("ha_types.hrl").


-export([
    generate_gid/0,
    new_msg_id/0,
    new_avatar_id/0,
    new_long_id/0,
    new_short_id/0,
    new_uuid/0
]).

-define(GID_SIZE, 22).

%% Export all functions for unit tests
-ifdef(TEST).
-compile(export_all).
-endif.

-spec generate_gid() -> binary().
generate_gid() ->
    GidPart = util:random_str(?GID_SIZE - 1),
    <<"g", GidPart/binary>>.


-spec new_msg_id() -> binary().
new_msg_id() ->
    new_long_id().


-spec new_avatar_id() -> binary().
new_avatar_id() ->
    new_long_id().


-spec new_uuid() -> binary().
new_uuid() ->
    list_to_binary(uuid:to_string(uuid:uuid1())).


-spec new_long_id() -> binary().
new_long_id() ->
    base64url:encode(crypto:strong_rand_bytes(18)).


%% wont be unique at scale.
-spec new_short_id() -> binary().
new_short_id() ->
    base64url:encode(crypto:strong_rand_bytes(3)).

