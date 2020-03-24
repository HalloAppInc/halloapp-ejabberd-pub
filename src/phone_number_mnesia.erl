%%%----------------------------------------------------------------------
%%% This module handles all the mnesia related queries with phone_number metadata to 
%%% - lookup region_metadata using their regionId or countrycode.
%%% - create table and insert entries .
%%% - check if a record is in the table or not based on the regionId.
%%%
%%% File    : phone_number_mnesia.erl
%%%
%%% Copyright (C) 2020 halloappinc.
%%%----------------------------------------------------------------------

-module(phone_number_mnesia).
-author('murali').
-include("phone_number.hrl").
-include("logger.hrl").

-export([init/0, close/0, insert/1, lookup/1, member/1, match_object_on_country_code/1]).


%% Record to hold all the necessary metadata about a region.
-record(phonenumber_metadata,
{
    id :: binary(),
    attributes_id :: undefined | binary(),
    attributes_country_code :: undefined | list(),
    attributes_main_country_for_code :: undefined | binary(),
    attributes_leading_digits :: undefined | list(),
    attributes_preferred_international_prefix :: undefined | list(),
    attributes_international_prefix :: undefined | list(),
    attributes_national_prefix :: undefined | list(),
    attributes_national_prefix_for_parsing :: undefined | list(),
    attributes_national_prefix_transform_rule :: undefined | list(),
    attributes_national_prefix_formatting_rule :: undefined | list(),
    attributes_national_prefix_optional_when_formatting :: undefined | binary(),
    attributes_carrier_code_formatting_rule :: undefined | list(),
    attributes_mobile_number_portable_region :: undefined | binary(),
    mobile_national_lengths :: undefined | list(),
    mobile_local_only_lengths :: undefined | list(),
    mobile_pattern :: undefined | list()
}).

%% clean up a bit.

init() ->
  case mnesia:create_table(?LIBPHONENUMBER_METADATA_TABLE,
                            [{disc_copies, [node()]},
                            {type, bag},
                            {record_name, phonenumber_metadata},
                            {attributes, record_info(fields, phonenumber_metadata)}]) of
    {atomic, _} -> ok;
    _ -> {error, db_failure}
  end.

close() ->
  ok.


%% Inserts the record into the table.
-spec insert(#region_metadata{}) -> {ok, any()} | {error, any()}.
insert(RegionMetadata) ->
  Record = convert_region_metadata_to_table_record(RegionMetadata),
  F = fun () ->
        mnesia:write(?LIBPHONENUMBER_METADATA_TABLE, Record, write),
        {ok, successful}
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
        ?DEBUG("Successfully inserted region_metadata for regionId: ~p, into the table: ~p",
                [RegionMetadata#region_metadata.id, ?LIBPHONENUMBER_METADATA_TABLE]),
        Result;
    {aborted, _Reason} ->
        ?ERROR_MSG("Failed inserting region_metadata for regionId: ~p, into the table: ~p",
                [RegionMetadata#region_metadata.id, ?LIBPHONENUMBER_METADATA_TABLE]),
        {error, db_failure}
  end.


%% Look up elements in the table based on the region id.
-spec lookup(binary()) -> [] | [#region_metadata{}].
lookup(RegionId) ->
  F = fun () ->
        Result = mnesia:read(?LIBPHONENUMBER_METADATA_TABLE, RegionId),
        convert_table_records_to_region_metadata(Result)
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
        ?DEBUG("Successfully retrieved region_metadata for RegionId: ~p, from the table: ~p",
                [RegionId, ?LIBPHONENUMBER_METADATA_TABLE]),
        Result;
    {aborted, _Reason} ->
        ?ERROR_MSG("Failed retrieving region_metadata for RegionId: ~p, from the table: ~p",
                [RegionId, ?LIBPHONENUMBER_METADATA_TABLE]),
        []
  end.


%% Look up elements in the table based on the region id and returns a boolean value.
-spec member(binary()) -> true | false.
member(RegionId) ->
  check_status(lookup(RegionId)).

-spec check_status([any()]) -> boolean().
check_status([]) ->
  false;
check_status([_ | _]) ->
  true.


%% Look up elements in the table based on the country code.
-spec match_object_on_country_code(list()) -> [] | [#region_metadata{}].
match_object_on_country_code(CountryCode) ->
  F = fun () ->
        MatchHead = #phonenumber_metadata{attributes_country_code = CountryCode, _ = '_'},
        Result = mnesia:select(?LIBPHONENUMBER_METADATA_TABLE, [{MatchHead, [], ['$_']}]),
        convert_table_records_to_region_metadata(Result)
      end,
  case mnesia:transaction(F) of
    {atomic, Result} ->
        ?DEBUG("Successfully retrieved region_metadata for CountryCode: ~p, from the table: ~p",
                [CountryCode, ?LIBPHONENUMBER_METADATA_TABLE]),
        Result;
    {aborted, _Reason} ->
        ?ERROR_MSG("Failed retrieving region_metadata for CountryCode: ~p, from the table: ~p",
                [CountryCode, ?LIBPHONENUMBER_METADATA_TABLE]),
        []
  end.


-spec convert_region_metadata_to_table_record(#region_metadata{}) -> #phonenumber_metadata{}.
convert_region_metadata_to_table_record(RegionMetadata) ->
  Record = #phonenumber_metadata{
    id = RegionMetadata#region_metadata.id,
    attributes_id = RegionMetadata#region_metadata.attributes#attributes.id,
    attributes_country_code = RegionMetadata#region_metadata.attributes#attributes.country_code,
    attributes_main_country_for_code =
      RegionMetadata#region_metadata.attributes#attributes.main_country_for_code,
    attributes_leading_digits =
      RegionMetadata#region_metadata.attributes#attributes.leading_digits,
    attributes_preferred_international_prefix =
      RegionMetadata#region_metadata.attributes#attributes.preferred_international_prefix,
    attributes_international_prefix =
      RegionMetadata#region_metadata.attributes#attributes.international_prefix,
    attributes_national_prefix =
      RegionMetadata#region_metadata.attributes#attributes.national_prefix,
    attributes_national_prefix_for_parsing =
      RegionMetadata#region_metadata.attributes#attributes.national_prefix_for_parsing,
    attributes_national_prefix_transform_rule =
      RegionMetadata#region_metadata.attributes#attributes.national_prefix_transform_rule,
    attributes_national_prefix_formatting_rule =
      RegionMetadata#region_metadata.attributes#attributes.national_prefix_formatting_rule,
    attributes_national_prefix_optional_when_formatting =
      RegionMetadata#region_metadata.attributes#attributes.national_prefix_optional_when_formatting,
    attributes_carrier_code_formatting_rule =
      RegionMetadata#region_metadata.attributes#attributes.carrier_code_formatting_rule,
    attributes_mobile_number_portable_region =
      RegionMetadata#region_metadata.attributes#attributes.mobile_number_portable_region,
    mobile_national_lengths = RegionMetadata#region_metadata.mobile#mobile.national_lengths,
    mobile_local_only_lengths = RegionMetadata#region_metadata.mobile#mobile.local_only_lengths,
    mobile_pattern = RegionMetadata#region_metadata.mobile#mobile.pattern
  },
  Record.



-spec convert_table_records_to_region_metadata([#phonenumber_metadata{}]) ->
                                                                      [] | [#region_metadata{}].
convert_table_records_to_region_metadata([]) ->
  [];
convert_table_records_to_region_metadata([Match | Rest]) ->
  [convert_table_record_to_region_metadata(Match) |
    convert_table_records_to_region_metadata(Rest)].



-spec convert_table_record_to_region_metadata(#phonenumber_metadata{}) -> #region_metadata{}.
convert_table_record_to_region_metadata(Record) ->
  Attributes = #attributes{
    id = Record#phonenumber_metadata.attributes_id,
    country_code = Record#phonenumber_metadata.attributes_country_code,
    main_country_for_code = Record#phonenumber_metadata.attributes_main_country_for_code,
    leading_digits = Record#phonenumber_metadata.attributes_leading_digits,
    preferred_international_prefix =
      Record#phonenumber_metadata.attributes_preferred_international_prefix,
    international_prefix = Record#phonenumber_metadata.attributes_international_prefix,
    national_prefix = Record#phonenumber_metadata.attributes_national_prefix,
    national_prefix_for_parsing =
      Record#phonenumber_metadata.attributes_national_prefix_for_parsing,
    national_prefix_transform_rule =
      Record#phonenumber_metadata.attributes_national_prefix_transform_rule,
    national_prefix_formatting_rule =
      Record#phonenumber_metadata.attributes_national_prefix_formatting_rule,
    national_prefix_optional_when_formatting =
      Record#phonenumber_metadata.attributes_national_prefix_optional_when_formatting,
    carrier_code_formatting_rule =
      Record#phonenumber_metadata.attributes_carrier_code_formatting_rule,
    mobile_number_portable_region =
      Record#phonenumber_metadata.attributes_mobile_number_portable_region
  },
  Mobile = #mobile{
    national_lengths = Record#phonenumber_metadata.mobile_national_lengths,
    local_only_lengths = Record#phonenumber_metadata.mobile_local_only_lengths,
    pattern = Record#phonenumber_metadata.mobile_pattern
  },
  RegionMetadata = #region_metadata{
    id = Record#phonenumber_metadata.id,
    attributes = Attributes,
    mobile = Mobile
  },
  RegionMetadata.


