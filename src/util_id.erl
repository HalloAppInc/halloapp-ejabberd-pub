%%%----------------------------------------------------------------------
%%% File    : util_id.erl
%%%
%%% Copyright (C) 2021 halloappinc.
%%%
%%%----------------------------------------------------------------------

-module(util_id).
-author('murali').
-include("logger.hrl").
-include("packets.hrl").
-include("ha_types.hrl").


-export([
    generate_album_id/0,
    generate_gid/0,
    new_msg_id/0,
    new_avatar_id/0,
    new_long_id/0,
    new_short_id/0,
    new_uuid/0,
    next_short_id/1
]).

-define(GID_SIZE, 22).
-define(ALBUM_ID_SIZE, 22).


-spec generate_album_id() -> binary().
generate_album_id() ->
    LastPart = util:random_str(?ALBUM_ID_SIZE - 1),
    <<"a", LastPart/binary>>.


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

-spec next_short_id(Id :: binary()) -> binary().
next_short_id(Id) when byte_size(Id) < 8 ->
    Bin = base64url:decode(Id),
    BitSize = byte_size(Bin) * 8,
    <<IntId:BitSize/integer>> = Bin,
    IntId2 = (IntId + 1) rem trunc(math:pow(2, BitSize)),
    Bin2 = <<IntId2:BitSize/integer>>,
    base64url:encode(Bin2).

