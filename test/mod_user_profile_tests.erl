%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2022, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_user_profile_tests).
-author("josh").

-include("packets.hrl").
-include("tutil.hrl").

setup() ->
    tutil:setup([
        {redis, [redis_accounts]}
    ]).

set_bio_testparallel() ->
    Uid = tutil:generate_uid(?KATCHUP),
    BadText = util:to_binary("text over 150 chars " ++ ["a" || _ <- lists:seq(1,150)]),
    BadRequest = #pb_iq{from_uid = Uid, payload = #pb_set_bio_request{text = BadText}},
    BadResult = #pb_iq{to_uid = Uid, type = result, payload = #pb_set_bio_result{result = fail, reason = too_long}},
    GoodText = <<"text under 150 chars">>,
    GoodRequest = #pb_iq{from_uid = Uid, payload = #pb_set_bio_request{text = GoodText}},
    GoodResult = #pb_iq{to_uid = Uid, type = result, payload = #pb_set_bio_result{result = ok}},
    [
        ?_assertMatch(BadResult, mod_user_profile:process_local_iq(BadRequest)),
        ?_assertMatch(GoodResult, mod_user_profile:process_local_iq(GoodRequest))
    ].

set_links_testparallel() ->
    Uid = tutil:generate_uid(?KATCHUP),
    BadLink = #pb_link{type = not_a_valid_type, text = "no"},
    GoodLink = #pb_link{type = snapchat, text = "snapchat"},
    Request = fun(Link) -> #pb_iq{from_uid = Uid, payload = #pb_set_link_request{link = Link}} end,
    BadResult = #pb_iq{to_uid = Uid, type = result,
        payload = #pb_set_link_result{result = fail, reason = bad_type}},
    GoodResult = #pb_iq{to_uid = Uid, type = result,
        payload = #pb_set_link_result{result = ok}},
    [
        ?_assertMatch(BadResult, mod_user_profile:process_local_iq(Request(BadLink))),
        ?_assertMatch(GoodResult, mod_user_profile:process_local_iq(Request(GoodLink)))
    ].

get_user_profile_by_uid_no_user_testparallel() ->
    Uid1 = tutil:generate_uid(?KATCHUP),
    Uid2 = tutil:generate_uid(?KATCHUP),
    Request = #pb_iq{from_uid = Uid1, payload = #pb_user_profile_request{uid = Uid2}},
    Result = #pb_iq{to_uid = Uid1, type=result, payload = #pb_user_profile_result{
        result = fail,
        reason = no_user
    }},
    [
        ?_assertMatch(Result, mod_user_profile:process_local_iq(Request))
    ].

get_user_profile_by_uid_testparallel() ->
    Uid1 = tutil:generate_uid(?KATCHUP),
    Uid2 = tutil:generate_uid(?KATCHUP),
    ok = model_accounts:create_account(Uid2, <<>>, <<>>),
    ok = model_accounts:set_name(Uid2, <<>>),
    Request = #pb_iq{from_uid = Uid1, payload = #pb_user_profile_request{uid = Uid2}},
    Result = #pb_iq{to_uid = Uid1, type=result, payload = #pb_user_profile_result{
        result = ok,
        profile = model_accounts:get_user_profiles(Uid1, Uid2)
    }},
    [
        ?_assertMatch(Result, mod_user_profile:process_local_iq(Request))
    ].

get_user_profile_by_username_testparallel() ->
    Uid1 = tutil:generate_uid(?KATCHUP),
    Uid2 = tutil:generate_uid(?KATCHUP),
    Username = <<"Uid2">>,
    ok = model_accounts:create_account(Uid2, <<>>, <<>>),
    ok = model_accounts:set_name(Uid2, <<>>),
    true = model_accounts:set_username(Uid2, Username),
    Request = #pb_iq{from_uid = Uid1, payload = #pb_user_profile_request{username = Username}},
    Result = #pb_iq{to_uid = Uid1, type=result, payload = #pb_user_profile_result{
        result = ok,
        profile = model_accounts:get_user_profiles(Uid1, Uid2)
    }},
    [
        ?_assertMatch(Result, mod_user_profile:process_local_iq(Request))
    ].
