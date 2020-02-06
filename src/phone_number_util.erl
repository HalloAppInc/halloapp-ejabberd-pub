%%%----------------------------------------------------------------------
%%% This file creates the ets table to hold all the phonenumber metadata and invokes the parser
%%% to parse the xml file.
%%% We will be adding more relevant functions here to parse a given phone-number,
%%% format it and return the result.
%%%
%%% File    : phone_number_util.erl
%%%
%%% Copyright (C) 2019 halloappinc.
%%%----------------------------------------------------------------------

-module(phone_number_util).

-include("phone_number.hrl").
-include("logger.hrl").

-export([init/2, close/1]).


init(_Host, _Opts) ->
    create_libPhoneNumber_table(),
    load_phone_number_metadata().


close(_Host) ->
    ok.


-spec load_phone_number_metadata() -> ok.
load_phone_number_metadata() ->
    FilePhoneNumberMetadata = code:priv_dir(ejabberd) ++ "/xml/" ++ ?FILE_PHONE_NUMBER_METADATA,
    ?INFO_MSG("Parsing this xml file for regionMetadata: ~p", [FilePhoneNumberMetadata]),
    case phone_number_metadata_parser:parse_xml_file(FilePhoneNumberMetadata) of
        {ok, Reason} ->
            ?INFO_MSG("Full libPhoneNumber metadata has been inserted into ets: ~p", [Reason]);
        {error, Reason} ->
            ?ERROR_MSG("Failed parsing the xml file for some reason: ~p", [Reason])
    end,
    ok.


%% Creates an in-memory table using ets to be able to store all the libphonenumber metadata.
-spec create_libPhoneNumber_table() -> ok | error.
create_libPhoneNumber_table() ->
    try
        ?INFO_MSG("Trying to create a table for libPhoneNumber ~p",
                    [?LIBPHONENUMBER_METADATA_TABLE]),
        ets:new(?LIBPHONENUMBER_METADATA_TABLE,
                [named_table, public, bag, {keypos, 2},
                {write_concurrency, true}, {read_concurrency, true}]),
        ok
    catch
        _:badarg -> 
            ?INFO_MSG("Failed to create a table for libPhoneNumber: ~p",
                        [?LIBPHONENUMBER_METADATA_TABLE]),
            error
    end.

