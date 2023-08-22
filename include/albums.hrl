%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2023, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-author("josh").

-ifndef(ALBUMS).
-define(ALBUMS, 1).

-define(ALBUM_MEMBER_LIMIT, 256).
-define(MEDIA_ITEMS_PER_PAGE, 20).

-type album_id() :: binary().
-type role() :: owner | admin | contributor | viewer | none.
-type album_role() :: {role(), boolean()}.  %% boolean value indicates pending status
-type encoded_album_role() :: binary().  %% owner | admin | contributor | viewer | pending_admin | pending_contributor | pending_viewer | none.
-type location() :: {maybe(float()), maybe(float())}.  %% latitude, longitude
-type time_range() :: {maybe(pos_integer()), maybe(pos_integer()), maybe(integer())}.  %% start, end, offset
-type share_type() :: contribute | view.
-type share_access() :: invite_only | everyone.
-type user_album_type() :: all | member | invited.
-type member_actions_list() :: list({set, uid(), role(), Pending :: boolean(), Change :: integer()} |  %% Change describes the resulting change
    {remove, uid(), RemoveTheirMedia :: boolean(), Change :: integer()} | not_allowed).                %% on the number of members in the album

-record(album_member, {
    uid :: uid(),
    role :: role(),
    pending :: boolean()
}).
-type album_member() :: #album_member{}.

-record(album, {
    id :: album_id(),
    name :: maybe(binary()),
    owner :: maybe(uid()),
    time_range :: maybe(time_range()),
    location :: maybe(location()),
    can_view :: maybe(share_access()),
    can_contribute :: maybe(share_access()),
    members = [] :: list(album_member()),
    media_items  = [] :: list(pb_media_item()),
    cursor = <<>> :: binary()
}).
-type album() :: #album{}.

-endif.
