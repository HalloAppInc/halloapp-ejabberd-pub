-module(mod_ha_stats).
-author('nikola').
-behaviour(gen_mod).

-include("logger.hrl").
-include("xmpp.hrl").
-include("pubsub.hrl").

-export([start/2, stop/1, reload/3, mod_options/1, depends/2]).

-export([
    pubsub_publish_item/6,
    register_user/2,
    re_register_user/2,
    add_friend/3,
    remove_friend/3
]).


start(Host, _Opts) ->
    ejabberd_hooks:add(pubsub_publish_item, Host, ?MODULE, pubsub_publish_item, 50),
    ejabberd_hooks:add(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:add(add_friend, Host, ?MODULE, add_friend, 50),
    ejabberd_hooks:add(remove_friend, Host, ?MODULE, remove_friend, 50),
    ok.


stop(Host) ->
    ejabberd_hooks:delete(remove_friend, Host, ?MODULE, remove_friend, 50),
    ejabberd_hooks:delete(add_friend, Host, ?MODULE, add_friend, 50),
    ejabberd_hooks:delete(register_user, Host, ?MODULE, register_user, 50),
    ejabberd_hooks:delete(pubsub_publish_item, Host, ?MODULE, pubsub_publish_item, 50),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [{stat, hard}].

mod_options(_Host) ->
    [].


-spec pubsub_publish_item(Server :: binary(), Node :: binary(), Publisher :: jid(),
        Host :: jid(), ItemId :: binary(), Payloads :: [xmlel()]) -> ok.
pubsub_publish_item(_Server, _Node, Publisher, _Host, _ItemId, _Payloads) ->
    ?INFO_MSG("counting uid:~p", [Publisher]),
    stat:count("HA/feed", "post"),
    ok.


-spec register_user(Uid :: binary(), Server :: binary()) -> ok.
register_user(Uid, _Server) ->
    ?INFO_MSG("counting uid:~s", [Uid]),
    stat:count("HA/account", "registration"),
    ok.


-spec re_register_user(Uid :: binary(), Server :: binary()) -> ok.
re_register_user(Uid, _Server) ->
    ?INFO_MSG("counting uid:~s", [Uid]),
    stat:count("HA/account", "re_register"),
    ok.


-spec add_friend(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
add_friend(Uid, _Server, _ContactId) ->
    ?INFO_MSG("counting uid:~s", [Uid]),
    stat:count("HA/graph", "add_friend"),
    ok.


-spec remove_friend(UserId :: binary(), Server :: binary(), ContactId :: binary()) -> ok.
remove_friend(Uid, _Server, _ContactId) ->
    ?INFO_MSG("counting uid:~s", [Uid]),
    stat:count("HA/graph", "remove_friend"),
    ok.
