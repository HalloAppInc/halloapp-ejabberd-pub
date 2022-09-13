%%%-------------------------------------------------------------------
%%% @copyright (C) 2021, Halloapp Inc.
%%%-------------------------------------------------------------------
-module(util_hashcash_tests).
-author("vipin").

-include_lib("tutil.hrl").

extract_challenge_testparallel() ->
    Err = {error, wrong_hashcash_solution},
    {inparallel, [
        ?_assertEqual(Err, util_hashcash:extract_challenge(undefined)),
        ?_assertEqual(Err, util_hashcash:extract_challenge(<<>>)),
        ?_assertEqual(Err, util_hashcash:extract_challenge(
            <<"H:20:21600:halloapp.net:4PF4B5e0_spEr0b3n0OM4g:SHA-256">>)),
        ?_assertEqual(Err, util_hashcash:extract_challenge(
            <<"H:AB:21600:halloapp.net:4PF4B5e0_spEr0b3n0OM4g:SHA-256:SOL">>)),
        ?_assertEqual(
            {20, <<"H:20:21600:halloapp.net:4PF4B5e0_spEr0b3n0OM4g:SHA-256">>},
            util_hashcash:extract_challenge(
                <<"H:20:21600:halloapp.net:4PF4B5e0_spEr0b3n0OM4g:SHA-256:Sol">>))
    ]}.

construct_challenge_testparallel() ->
    Challenge = util_hashcash:construct_challenge(20, 21600),
    CList = binary:split(Challenge, <<":">>, [global]),
    DummySolution = <<Challenge/binary, ":Dummy">>,
    {inparallel, [
        ?_assertEqual(6, length(CList)),
        ?_assertEqual(<<"20">>, lists:nth(2, CList)),
        ?_assertEqual(<<"21600">>, lists:nth(3, CList)),
        ?_assertEqual(<<"halloapp.net">>, lists:nth(4, CList)),
        ?_assertEqual(20, byte_size(lists:nth(5, CList))),
        ?_assertEqual(<<"SHA-256">>, lists:nth(6, CList)),
        ?_assertEqual({20, Challenge}, util_hashcash:extract_challenge(DummySolution))
    ]}.


solution_testparallel() ->
    Challenge = util_hashcash:construct_challenge(10, 21600),
    Solution = util_hashcash:solve_challenge(Challenge),
    Sha = crypto:hash(sha256, Solution),
    <<First:2/binary, _Second/binary>> = Sha,
    <<FirstInt:16>> = First,
    {inparallel, [
        ?_assertEqual( 
            <<"H:10:21600:halloapp.net:naiZp8cPTVtc4189sL-S:SHA-256:AAAAAAAAAOY">>,
            util_hashcash:solve_challenge(<<"H:10:21600:halloapp.net:naiZp8cPTVtc4189sL-S:SHA-256">>)
            ),
        ?_assertEqual({10, Challenge}, util_hashcash:extract_challenge(Solution)),
        ?_assert(util_hashcash:validate_solution(10, Solution)),
        ?_assert(FirstInt < 1 bsl 7)
    ]}.


