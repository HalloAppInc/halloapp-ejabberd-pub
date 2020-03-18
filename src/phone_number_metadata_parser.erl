%%%----------------------------------------------------------------------
%%% Parses the phonenumbermetadata xml resource file containing the information for all countries
%%% and creates records for each country and inserts them into the table created using ETS.
%%%
%%% File    : phone_number_metadata_parser.erl
%%%
%%% Copyright (C) 2019 halloappinc.
%%%
%%%----------------------------------------------------------------------

-module(phone_number_metadata_parser).

-include_lib("phone_number.hrl").
-include_lib("xmerl/include/xmerl.hrl").
-include("logger.hrl").


%% API
-export([parse_xml_file/1]).


%% Parse the xml file and insert the records obtained into the ets table.
%% Assumes that the ets table has already been created.
-spec parse_xml_file(file:filename()) -> {ok, any()} | {error, any()}.
parse_xml_file(FileName) ->
  case xmerl_scan:file(FileName) of
    {XmlContents, _} ->
      ?INFO_MSG("Parsing xml contents here: ~p", [XmlContents]),
      #xmlElement{content = [_, TerritoryElements, _]} = XmlContents,
      Result = parse_territories(TerritoryElements#xmlElement.content),
      {ok, Result};
    _ ->
      {error, failed}
  end.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%% Parse the territory elements and extract the necessary information from its attributes and
%% child-elements and then inserts them using ets.
-spec parse_territories(list(#xmlElement{} | #xmlComment{})) -> ok.
parse_territories([]) ->
  ok;

parse_territories([#xmlComment{} | Rest]) ->
  parse_territories(Rest);

parse_territories([Territory = #xmlElement{name = territory} | Rest]) ->
  #xmlElement{name = territory, attributes = Attributes, content = Content} = Territory,
  RegionAttributes = parse_attributes(Attributes, #attributes{}),
  RegionMobile = parse_mobile_content(Content, #mobile{}),
  RegionId = RegionAttributes#attributes.id,
  case RegionId of
    undefined ->
      ?ERROR_MSG("Something is wrong with this territory: unable to parse it: ~p", [Territory]);
    _ ->
      RegionMetadata = #region_metadata{id = RegionId, attributes = RegionAttributes,
                                        mobile = RegionMobile},
      ?DEBUG("Extracted metadata for territory with regionId: ~p, with metadata: ~p", [RegionId,
              RegionMetadata]),
      phone_number_mnesia:insert(RegionMetadata)
  end,
  parse_territories(Rest);

parse_territories([_ | Rest]) ->
  parse_territories(Rest).


%% Parse attributes for the territory element to get the necessary attribute values.
-spec parse_attributes(list(#xmlAttribute{}), #attributes{}) -> #attributes{}.
parse_attributes([], State) ->
  State;
parse_attributes([#xmlAttribute{name = id, value = Id} | Rest], State) ->
  parse_attributes(Rest, State#attributes{id = list_to_binary(Id)});

parse_attributes([#xmlAttribute{name = countryCode, value = Value} | Rest], State) ->
  parse_attributes(Rest, State#attributes{country_code = Value});

parse_attributes([#xmlAttribute{name = mainCountryForCode, value = Value} | Rest], State) ->
  parse_attributes(Rest, State#attributes{main_country_for_code = list_to_binary(Value)});

parse_attributes([#xmlAttribute{name = leadingDigits, value = Value} | Rest], State) ->
  parse_attributes(Rest, State#attributes{leading_digits = Value});

parse_attributes([#xmlAttribute{name = preferredInternationalPrefix, value = Value} | Rest],
                  State) ->
  parse_attributes(Rest, State#attributes{preferred_international_prefix = Value});

parse_attributes([#xmlAttribute{name = internationalPrefix, value = Value} | Rest], State) ->
  parse_attributes(Rest, State#attributes{international_prefix = Value});

parse_attributes([#xmlAttribute{name = nationalPrefix, value = Value} | Rest], State) ->
  parse_attributes(Rest, State#attributes{national_prefix = Value});

parse_attributes([#xmlAttribute{name = nationalPrefixForParsing, value = Value} | Rest], State) ->
  parse_attributes(Rest, State#attributes{national_prefix_for_parsing = Value});

parse_attributes([#xmlAttribute{name = nationalPrefixTransformRule, value = Value} | Rest],
                  State) ->
  parse_attributes(Rest, State#attributes{national_prefix_transform_rule = Value});

parse_attributes([#xmlAttribute{name = nationalPrefixFormattingRule, value = Value} | Rest],
                  State) ->
  parse_attributes(Rest, State#attributes{national_prefix_formatting_rule = Value});

parse_attributes([#xmlAttribute{name = nationalPrefixOptionalWhenFormatting, value = Value} | Rest],
                  State) ->
  parse_attributes(Rest, State#attributes{national_prefix_optional_when_formatting =
                  list_to_binary(Value)});

parse_attributes([#xmlAttribute{name = carrierCodeFormattingRule, value = Value} | Rest], State) ->
  parse_attributes(Rest, State#attributes{carrier_code_formatting_rule = Value});

parse_attributes([#xmlAttribute{name = mobileNumberPortableRegion, value = Value} | Rest], State) ->
  parse_attributes(Rest, State#attributes{mobile_number_portable_region = list_to_binary(Value)});

parse_attributes([_ | Rest], State) ->
  parse_attributes(Rest, State).




%% Parse child elements for mobile to get the necessary details.
-spec parse_mobile_content(list(#xmlElement{}), #mobile{}) -> #mobile{}.
parse_mobile_content([], State) ->
  State;

parse_mobile_content([#xmlElement{name = mobile, content = Content} | Rest], State) ->
    NewState = get_pattern_and_lengths(Content, State),
    parse_mobile_content(Rest, NewState);

parse_mobile_content([_ | Rest], State) ->
  parse_mobile_content(Rest, State).




%% Parse child elements of mobile element to get values for nationalNumberPattern & possibleLengths.
-spec get_pattern_and_lengths(list(), #mobile{}) -> #mobile{}.
get_pattern_and_lengths([], State) ->
  State;

get_pattern_and_lengths([#xmlElement{name = possibleLengths, attributes = Attributes} | Rest],
                        State) ->
  NewState = parse_attributes_for_length(Attributes, State),
  get_pattern_and_lengths(Rest, NewState);

get_pattern_and_lengths([#xmlElement{name = nationalNumberPattern, content = C} | Rest], State) ->
  [PatternVal] = [V || #xmlText{value = V} <- C],
  Pattern = re:replace(PatternVal, "\s+|\n|\t", "", [global, {return, binary}]),
  get_pattern_and_lengths(Rest, State#mobile{pattern = Pattern});

get_pattern_and_lengths([_|Rest], State) ->
  get_pattern_and_lengths(Rest, State).



%% Parse attributes for possibleLengths element to get attribute values for: national and localOnly
-spec parse_attributes_for_length(list(#xmlAttribute{}), #mobile{}) -> #mobile{}.
parse_attributes_for_length([], State) ->
  State;

parse_attributes_for_length([#xmlAttribute{name = national, value = Value} | Rest], State) ->
  parse_attributes_for_length(Rest, State#mobile{national_lengths = Value});

parse_attributes_for_length([#xmlAttribute{name = localOnly, value = Value} | Rest], State) ->
  parse_attributes_for_length(Rest, State#mobile{local_only_lengths = Value});

parse_attributes_for_length([_ | Rest], State) ->
  parse_attributes_for_length(Rest, State).


