%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, Halloapp Inc.
%%%-------------------------------------------------------------------
-module(util_hashcash_tests).
-author("vipin").

-include_lib("eunit/include/eunit.hrl").

extract_challenge_test() ->
    {error, wrong_hashcash_solution} = util_hashcash:extract_challenge(
        <<"H:20:21600:halloapp.net:4PF4B5e0_spEr0b3n0OM4g:SHA-256">>),
    {error, wrong_hashcash_solution} = util_hashcash:extract_challenge(
        <<"H:AB:21600:halloapp.net:4PF4B5e0_spEr0b3n0OM4g:SHA-256:SOL">>),
    {20, <<"H:20:21600:halloapp.net:4PF4B5e0_spEr0b3n0OM4g:SHA-256">>} =
        util_hashcash:extract_challenge(
            <<"H:20:21600:halloapp.net:4PF4B5e0_spEr0b3n0OM4g:SHA-256:Sol">>).

construct_challenge_test() ->
    Challenge = util_hashcash:construct_challenge(20, 21600),
    CList = binary:split(Challenge, <<":">>, [global]),
    6 = length(CList),
    <<"20">> = lists:nth(2, CList),
    <<"21600">> = lists:nth(3, CList),
    <<"halloapp.net">> = lists:nth(4, CList),
    20 = byte_size(lists:nth(5, CList)),
    <<"SHA-256">> = lists:nth(6, CList),
    DummySolution = <<Challenge/binary, ":Dummy">>,
    {20, Challenge} = util_hashcash:extract_challenge(DummySolution).


solution_test() ->
    <<"H:10:21600:halloapp.net:naiZp8cPTVtc4189sL-S:SHA-256:AAAAAAAAAOY">> =
        util_hashcash:solve_challenge(<<"H:10:21600:halloapp.net:naiZp8cPTVtc4189sL-S:SHA-256">>),
    Challenge = util_hashcash:construct_challenge(10, 21600),
    Solution = util_hashcash:solve_challenge(Challenge),
    {10, Challenge} = util_hashcash:extract_challenge(Solution),
    ?assert(util_hashcash:validate_solution(10, Solution)),
    Sha = crypto:hash(sha256, Solution),
    <<First:2/binary, _Second/binary>> = Sha,
    <<FirstInt:16>> = First,
    ?assert(FirstInt < 1 bsl 7).


