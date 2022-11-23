%%%----------------------------------------------------------------------
%%% File    : list_processor.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%
%%% Functions to handle list of items, e.g. for removing a list of users.
%%%----------------------------------------------------------------------

-module(list_processor).
-author('vipin').

-include_lib("stdlib/include/assert.hrl").

-include("logger.hrl").

-export([
    process_file_list/3,
    remove_user/1,
    validate_phone/1   
]).


-define(SERVER, <<"s.halloapp.net">>).

-type item_process_fun() :: fun((integer()) -> boolean()).

-spec process_file_list(
    FileName :: string(), ProcessFun :: item_process_fun(), MaxToProcess :: integer()) -> integer().
process_file_list(FileName, ProcessFun, MaxToProcess) ->
    {ok, Res} = file:read_file(FileName),
    Res2 = binary:split(Res, [<<"\n">>], [global]),
    process_list(Res2, 0, ProcessFun, MaxToProcess).

process_list([], Count, _ProcessFun, _MaxToProcess) -> Count;
process_list([<<>>], Count, _ProcessFun, _MaxToProcess) -> Count;
process_list([X | Rest], Count, ProcessFun, MaxToProcess) ->
    Item = binary_to_list(X),
    ItemLen = string:length(Item),
    ?assert(ItemLen > 6),
    Content = string:slice(Item, 3, ItemLen - 6),
    ?DEBUG("Processing: ~p", [Content]),
    IntContent = list_to_integer(Content),
    ProcessResult = ProcessFun(IntContent),
    NewCount = case ProcessResult of
        false ->
            ?INFO("~p not processed", [IntContent]),
            Count;
        true ->
            ?INFO("~p processed", [IntContent]),
            Count + 1
    end,
    case NewCount < MaxToProcess of
        true -> process_list(Rest, NewCount, ProcessFun, MaxToProcess);
        false ->
              ?INFO("Done processing"),
              NewCount
    end.

-spec remove_user(Uid :: integer()) -> boolean().
remove_user(Uid) ->
    UidBin = integer_to_binary(Uid),
    case ejabberd_auth:user_exists(UidBin) of
        true ->
            ok = ejabberd_auth:remove_user(UidBin, ?SERVER),
            true;
        false -> false
    end.

-spec validate_phone(PhoneInt :: integer()) -> boolean().
validate_phone(PhoneInt) ->
    Phone = integer_to_binary(PhoneInt),
    case model_phone:get_uid(Phone, halloapp) of
        {ok, undefined} ->
            ?INFO("No Uid for: ~p", [Phone]),
            false;
        {ok, Uid} ->
            case model_accounts:get_phone(Uid) of
                {ok, GotPhone} -> GotPhone =:= Phone;
                {error, _} -> false
            end
    end.
