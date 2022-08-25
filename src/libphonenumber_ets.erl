%%%---------------------------------------------------------------------------------
%%% This module handles all the ets related queries with phone_number metadata to
%%% - lookup region_metadata using their regionId or countrycode.
%%% - create table and insert entries .
%%% - check if a record is in the table or not based on the regionId.
%%%
%%% File    : libphonenumber_ets.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%---------------------------------------------------------------------------------

-module(libphonenumber_ets).
-author('murali').
-include("phone_number.hrl").
-include("logger.hrl").

-export([init/0, close/0, insert/1, lookup/1, member/1, match_object_on_country_code/1]).


init() ->
    try
        ?INFO("Trying to create a table for libPhoneNumber in ets", []),
        ets:new(?LIBPHONENUMBER_METADATA_TABLE,
                [named_table, public, bag, {keypos, 2},
                {write_concurrency, true}, {read_concurrency, true}]),
        ok
    catch
        Error:badarg ->
            ?INFO("Failed to create a table for libPhoneNumber in ets: ~p", [Error]),
            error
    end.

close() ->
    ok.


%% Inserts the record into the table.
-spec insert(#region_metadata{}) -> true.
insert(RegionMetadata) ->
    true = ets:insert(?LIBPHONENUMBER_METADATA_TABLE, RegionMetadata).


%% Look up elements in the table based on the region id.
-spec lookup(binary()) -> [] | [#region_metadata{}].
lookup(RegionId) ->
    ets:lookup(?LIBPHONENUMBER_METADATA_TABLE, RegionId).


%% Look up elements in the table based on the region id and returns a boolean value.
-spec member(binary()) -> true | false.
member(RegionId) ->
    ets:member(?LIBPHONENUMBER_METADATA_TABLE, RegionId).


%% Look up elements in the table based on the country code.
-spec match_object_on_country_code(list()) -> [] | [#region_metadata{}].
match_object_on_country_code(CountryCode) ->
    ets:match_object(?LIBPHONENUMBER_METADATA_TABLE, #region_metadata{
            attributes = #attributes{country_code = CountryCode, _ = '_'}, _ = '_'}).

