%%%----------------------------------------------------------------------
%%% Custom xml records to parse the phonenumbermetadata xml resource file containing
%%%  the information for all countries.
%%%
%%% File    : phone_number.hrl
%%%
%%% Copyright (C) 2019 halloappinc.
%%%
%%%----------------------------------------------------------------------

-ifndef(PHONE_NUMBER_HRL).
-define(PHONE_NUMBER_HRL, 1).

-include("ha_types.hrl").

-define(FILE_PHONE_NUMBER_METADATA, "PhoneNumberMetadata.xml").

%% name of the table to hold all the country code information.
-define(LIBPHONENUMBER_METADATA_TABLE, phonenumber_metadata).


%% Necessary attributes of the xml element territory in the phonenumbermetadata xml file.
-record(attributes,
{
    id :: binary() | '_',
    country_code :: list(),
    main_country_for_code :: binary() | '_',
    leading_digits :: maybe(list()) | '_',
    preferred_international_prefix :: list() | '_',
    international_prefix :: list() | '_',
    national_prefix :: list() | '_',
    national_prefix_for_parsing :: maybe(list()) | '_',
    national_prefix_transform_rule :: maybe(list()) | '_',
    national_prefix_formatting_rule :: list() | '_',
    national_prefix_optional_when_formatting :: binary() | '_',
    carrier_code_formatting_rule :: list() | '_',
    mobile_number_portable_region :: binary() | '_'
}).

%% Necessary elements of the mobile child element in the phonenumbermetadata xml file.
-record(number_type,
{
    type :: atom(),
    national_lengths :: maybe(list()),
    local_only_lengths :: maybe(list()),
    pattern :: maybe(list())
}).

%% Record to hold all the necessary metadata about a region.
-record(region_metadata,
{
    id :: binary() | '_',
    attributes = #attributes{},
    number_types :: list() | '_' % list of number types (mobile, voip, fixed line)
}).

%% Type of country code source.
-type(countryCodeSource() :: 'fromNumberWithPlusSign'
                      | 'fromNumberWithIdd'
                      | 'fromNumberWithoutPlusSign'
                      | 'fromDefaultCountry'
                      | 'unspecified'
).

%% Type of error messages.
-type(errorMsg() :: undefined_num
                | undefined_country_code
                | undefined_national_num
                | undefined_region
                | invalid_country_code  % cc does not exist/unrecognized
                | invalid_region        % no metadata for the region
                | no_region_id          % no region id available
                | mismatch_cc_region    % cc does not match region metadata's cc
                | too_short
                | too_long
                | invalid_length        % length cannot be checked against (missing) region metadata
                | line_type_voip
                | line_type_fixed
                | line_type_other       % not mobile, voip, or fixed line
).

%% Record to hold all the necessary information about a phone_number as state when processing it.
-record(phone_number_state,
{
    country_code :: maybe(list()),
    national_number :: maybe(list()),
    phone_number :: maybe(list()),
    raw :: maybe(list()),
    valid :: maybe(boolean()),
    e164_value :: maybe(list()),
    country_code_source :: maybe(countryCodeSource()),
    error_msg :: errorMsg()
}).

-endif.

