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
    BadRequest = #pb_iq{type = set, from_uid = Uid, payload = #pb_set_bio_request{text = BadText}},
    BadResult = #pb_iq{to_uid = Uid, type = result, payload = #pb_set_bio_result{result = fail, reason = too_long}},
    GoodText = <<"text under 150 chars">>,
    GoodRequest = #pb_iq{type = set, from_uid = Uid, payload = #pb_set_bio_request{text = GoodText}},
    GoodResult = #pb_iq{to_uid = Uid, type = result, payload = #pb_set_bio_result{result = ok}},
    [
        ?_assertMatch(BadResult, mod_user_profile:process_local_iq(BadRequest)),
        ?_assertMatch(GoodResult, mod_user_profile:process_local_iq(GoodRequest))
    ].

set_links_testparallel() ->
    Uid = tutil:generate_uid(?HALLOAPP),
    BadLink = #pb_link{type = not_a_valid_type, text = "no"},
    GoodLink = #pb_link{type = x, text = "not twitter"},
    Request = fun(Link, Action) -> #pb_iq{type = set, from_uid = Uid, payload = #pb_set_link_request{link = Link, action = Action}} end,
    BadSetResult = #pb_iq{to_uid = Uid, type = result,
        payload = #pb_set_link_result{result = fail, reason = bad_type}},
    GoodSetResult = #pb_iq{to_uid = Uid, type = result,
        payload = #pb_set_link_result{result = ok}},
    BadRemoveResult = #pb_iq{to_uid = Uid, type = result,
        payload = #pb_set_link_result{result = fail, reason = bad_type}},
    GoodRemoveResult = #pb_iq{to_uid = Uid, type = result,
        payload = #pb_set_link_result{result = ok}},
    [
        ?_assertMatch(BadSetResult, mod_user_profile:process_local_iq(Request(BadLink, set))),
        ?_assertMatch(GoodSetResult, mod_user_profile:process_local_iq(Request(GoodLink, set))),
        ?_assertEqual([{x, "not twitter"}], model_accounts:get_links(Uid)),
        ?_assertMatch(BadRemoveResult, mod_user_profile:process_local_iq(Request(BadLink, remove))),
        ?_assertMatch(GoodRemoveResult, mod_user_profile:process_local_iq(Request(GoodLink, remove))),
        ?_assertEqual([], model_accounts:get_links(Uid))
    ].

set_links_katchup_testparallel() ->
    Uid = tutil:generate_uid(?KATCHUP),
    BadLink = #pb_link{type = not_a_valid_type, text = "no"},
    GoodLink = #pb_link{type = instagram, text = "instagram"},
    Request = fun(Link) -> #pb_iq{type = set, from_uid = Uid, payload = #pb_set_link_request{link = Link}} end,
    BadResult = #pb_iq{to_uid = Uid, type = result,
        payload = #pb_set_link_result{result = fail, reason = bad_type}},
    GoodResult = #pb_iq{to_uid = Uid, type = result,
        payload = #pb_set_link_result{result = ok}},
    [
        ?_assertMatch(BadResult, mod_user_profile:process_local_iq_katchup(Request(BadLink))),
        ?_assertMatch(GoodResult, mod_user_profile:process_local_iq_katchup(Request(GoodLink)))
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
    Username = <<"UidUid2">>,
    ok = model_accounts:create_account(Uid2, <<>>, <<>>),
    true = model_accounts:set_username(Uid2, Username),
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
    true = model_accounts:set_username(Uid2, Username),
    ok = model_accounts:set_name(Uid2, <<>>),
    Request = #pb_iq{from_uid = Uid1, payload = #pb_user_profile_request{username = Username}},
    Result = #pb_iq{to_uid = Uid1, type=result, payload = #pb_user_profile_result{
        result = ok,
        profile = model_accounts:get_user_profiles(Uid1, Uid2)
    }},
    [
        ?_assertMatch(Result, mod_user_profile:process_local_iq(Request))
    ].
