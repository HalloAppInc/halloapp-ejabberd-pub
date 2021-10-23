%%%----------------------------------------------------------------------
%%% File    : util_hashcash.erl
%%%
%%% Copyright (C) 2021 halloappinc.
%%%
%%% Implements util functions for Hashcash.
%%%----------------------------------------------------------------------

-module(util_hashcash).
-author('vipin').

-include("logger.hrl").
-include("time.hrl").

-define(HEADER_TAG, <<"H">>).
-define(DOMAIN_TAG, <<"halloapp.net">>).
-define(CRYPTO_TAG, <<"SHA-256">>).

-export([
    extract_challenge/1,
    construct_challenge/2,
    solve_challenge/1,
    validate_solution/2
]).

%% Extracts {Difficulty: Tag 2, Challenge: Everything other than last Tag} from Solution.
-spec extract_challenge(Solution :: binary()) -> {error, atom()} | {integer(), binary()}.
extract_challenge(Solution) ->
    %% Example: `H:20:21600:halloapp.net:4PF4B5e0_spEr0b3n0OM4g:SHA-256:eHQPAA`
    Segments = binary:split(Solution, <<":">>, [global]),
    NumSegments = length(Segments),
    if
        NumSegments =/= 7 ->
            {error, wrong_hashcash_solution};
        true ->
            Difficulty = lists:nth(2, Segments),
            DifficultyInt = try binary_to_integer(Difficulty)
                catch error : badarg : _ ->
                    ?ERROR("Unable to convert to int. Difficulty: ~p Hashcash solution: ~p",
                        [Difficulty, Solution]),
                    -1
                end,
            ChallengeList = lists:droplast(Segments),
            Challenge = iolist_to_binary(lists:join(":", ChallengeList)),
            case DifficultyInt of
                -1 -> {error, wrong_hashcash_solution};
                _ -> {DifficultyInt, Challenge}
            end
    end.

-spec construct_challenge(Difficulty :: integer(), ExpireIn :: integer()) -> binary().
construct_challenge(Difficulty, ExpireIn) ->
    DifficultyBin = integer_to_binary(Difficulty),
    ExpireInBin = integer_to_binary(ExpireIn),
    NonceBin = util:random_str(20),
    Challenge = <<?HEADER_TAG/binary, ":", DifficultyBin/binary, ":", ExpireInBin/binary, ":",
        ?DOMAIN_TAG/binary, ":", NonceBin/binary, ":", ?CRYPTO_TAG/binary>>,
    ?DEBUG("Constructed: ~p", [Challenge]),
    Challenge.

-spec solve_challenge(Challenge :: binary()) -> binary().
solve_challenge(Challenge) ->
    Segments = binary:split(Challenge, <<":">>, [global]),
    Difficulty = binary_to_integer(lists:nth(2, Segments)),
    hashcash_iterate(Challenge, Difficulty, 0).

hashcash_iterate(Challenge, Difficulty, LastPart) ->
    LastPartBytes = <<LastPart:64>>,
    LastPartEncoded = base64url:encode(LastPartBytes),
    PossibleSol = <<Challenge/binary, ":", LastPartEncoded/binary>>,
    case validate_solution(Difficulty, PossibleSol) of
        true -> PossibleSol;
        _ -> hashcash_iterate(Challenge, Difficulty, LastPart + 1)
    end.


-spec validate_solution(Difficulty :: integer(), Solution :: binary()) -> boolean().
validate_solution(Difficulty, Solution) ->
    Sha = crypto:hash(sha256, Solution),
    SizeShaBits = byte_size(Sha) * 8,
    <<ShaInt:SizeShaBits>> = Sha,
    Prefix = ShaInt bsr (SizeShaBits - Difficulty),
    Prefix =:= 0.
  
