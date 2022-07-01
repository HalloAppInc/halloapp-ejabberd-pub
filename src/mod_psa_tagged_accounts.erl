%%%-------------------------------------------------------------------
%%% File: mod_psa_tagged_accounts.erl
%%% copyright (C) 2021, HalloApp, Inc.
%%%
%%% Module to manage psa tagged accounts.
%%%
%%%-------------------------------------------------------------------
-module(mod_psa_tagged_accounts).
-author('vipin').
-behaviour(gen_mod).

-include("logger.hrl").
-include("feed.hrl").
-include("packets.hrl").
-include("time.hrl").
-include("util_redis.hrl").
-include("account.hrl").

%% gen_mod callbacks
-export([start/2, stop/1, mod_options/1, depends/2]).

-export([
    schedule/0,
    unschedule/0,
    send_psa_moment/1,
    send_psa_moments/0,
    find_uids/0,
    find_psa_tagged_accounts/2
]).

%%====================================================================
%% gen_mod callbacks
%%====================================================================

start(_Host, _Opts) ->
    ?INFO("start ~w", [?MODULE]),
    case util:get_machine_name() of
        <<"s-test">> -> schedule();
        _ -> ok
    end,
    ok.


stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    case util:get_machine_name() of
        <<"s-test">> -> unschedule();
        _ -> ok
    end,
    ok.

depends(_Host, _Opts) ->
    [].

mod_options(_Host) ->
    [].


%%====================================================================
%% api
%%====================================================================

-spec schedule() -> ok.
schedule() ->
    erlcron:cron(send_psa_moments, {
        {daily, {every, {2, hr}}},
        {?MODULE, send_psa_moments, []}
    }),
    ok.

-spec unschedule() -> ok.
unschedule() ->
    erlcron:cancel(send_psa_moments),
    ok.

-spec send_psa_moments() -> ok.
send_psa_moments() ->
    %% send_psa_moment(<<"SR">>),
    %% To get rid of compile warnings.
    send_psa_moment(<<"RS">>),
    ok.

-spec find_uids() -> ok.
find_uids() ->
    redis_migrate:start_migration("Find PSA Tagged Accounts", redis_accounts,
        {?MODULE, find_psa_tagged_accounts},
        [{dry_run, false}, {execute, sequential}]),
    ok.

%%====================================================================

-spec send_psa_moment(PSATag :: binary()) -> ok.
send_psa_moment(PSATag) ->
    case model_feed:is_psa_tag_done(PSATag) of
        true -> ok;
        false -> process_psa_tag(PSATag)
    end.

process_psa_tag(PSATag) ->
    Processed2 = lists:foldl(
        fun(Slot, Processed) ->
            {ok, List} = model_accounts:get_psa_tagged_uids(Slot, PSATag),
            ?INFO("Sending PSA Moment accounts in slot: ~p, Tag: ~p, list: ~p", [Slot, PSATag, List]),
            Phones = model_accounts:get_phones(List),
            UidPhones = lists:zip(List, Phones),
            lists:foldl(fun({Uid, Phone}, Acc) ->
                ProcessingDone = case is_timezone_ok(Phone) of
                    true ->
                          maybe_send_psa_moment(Uid, PSATag),
                          true;
                    false -> false
                end,
                Acc and ProcessingDone
            end, Processed, UidPhones)
        end, true, lists:seq(0, ?NUM_SLOTS - 1)),
    case Processed2 of
        true -> model_feed:mark_psa_tag_done(PSATag);
        false -> ok
    end.

is_timezone_ok(Phone) ->
    CC = mod_libphonenumber:get_cc(Phone),
    {{_,_,_}, {UtcHr,_,_}} = calendar:now_to_universal_time(erlang:timestamp()),
    UtcHr2 = UtcHr + 24,
    CCLocalHr1 = case CC of
        <<"SR">> -> UtcHr2 - 3;
        <<"US">> -> UtcHr2 - 6;
        <<"IN">> -> UtcHr2 + 5;
        _ -> UtcHr2
    end,
    CCLocalHr = CCLocalHr1 rem 24,
    (CCLocalHr >= 9) andalso (CCLocalHr =< 21).


-spec maybe_send_psa_moment(Uid :: uid(), PSATag :: binary()) -> ok.
maybe_send_psa_moment(Uid, PSATag) ->
    {ok, Posts} = model_feed:get_psa_tag_posts(PSATag),
    PostStanzas = lists:map(fun convert_post_to_feeditem/1, Posts),
    lists:foreach(fun(#pb_feed_item{item = #pb_post{id = PostId, publisher_uid = FromUid}} = PostStanza) ->
        ?INFO("Processing Post: ~p, Uid: ~p", [PostStanza, Uid]),
        case model_accounts:mark_psa_post_sent(Uid, PostId) of
            true ->
                Packet = #pb_msg{
                    id = util_id:new_msg_id(),
                    to_uid = Uid,
                    from_uid = FromUid,
                    type = headline,
                    payload = PostStanza
                },
                ejabberd_router:route(Packet);
            false ->
                ?DEBUG("Post: ~p, already sent to Uid: ~p", [PostId, Uid])
        end
    end, PostStanzas),
    ok.

-spec convert_post_to_feeditem(post()) -> pb_post().
convert_post_to_feeditem(#post{id = PostId, uid = Uid, payload = PayloadBase64, ts_ms = TimestampMs, audience_type = AudienceType, tag = Tag, psa_tag = PSATag}) ->
    #pb_feed_item{
        action = publish,
        item = #pb_post{
            id = PostId,
            publisher_uid = Uid,
            publisher_name = model_accounts:get_name_binary(Uid),
            payload = base64:decode(PayloadBase64),
            timestamp = util:ms_to_sec(TimestampMs),
            audience = #pb_audience{type = AudienceType},
            tag = Tag,
            psa_tag = PSATag
        }
    }.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%                         Generate List of inactive users                            %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
find_psa_tagged_accounts(Key, State) ->
    DryRun = maps:get(dry_run, State, false),
    Result = re:run(Key, "^acc:{([0-9]+)}$", [global, {capture, all, binary}]),
    case Result of
        {match, [[_FullKey, Uid]]} ->
            ?INFO("Account uid: ~p", [Uid]),
            try
                {ok, Phone} = model_accounts:get_phone(Uid),
                case {DryRun, mod_libphonenumber:get_cc(Phone)} of
                    {true, <<"SR">>} -> model_accounts:add_uid_to_psa_tag(Uid, <<"SR">>);
                    {false, <<"SR">>} -> ?INFO("Will add: ~p to \"SR\" PSA Tag", [Uid]);
                    {_, _} -> ok
                end
            catch
                Class:Reason:Stacktrace ->
                    ?ERROR("Unable to process Uid: ~p, Stacktrace:~s", [Uid, lager:pr_stacktrace(Stacktrace, {Class, Reason})])
            end;
        _ -> ok
    end,
    {ok, State}.

