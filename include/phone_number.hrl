%%%----------------------------------------------------------------------
%%% Custom xml records to parse the phonenumbermetadata xml resource file containing
%%%  the information for all countries.
%%%
%%% File    : phone_number.hrl
%%%
%%% Copyright (C) 2019 halloappinc.
%%%
%%%----------------------------------------------------------------------

-define(FILE_PHONE_NUMBER_METADATA, "PhoneNumberMetadata.xml").

%% name of the table to hold all the country code information.
-define(LIBPHONENUMBER_METADATA_TABLE, libphonenumber_metadata).


%% Necessary attributes of the xml element territory in the phonenumbermetadata xml file.
-record(attributes,
{
    id :: binary(),
    country_code :: list(),
    main_country_for_code :: binary(),
    leading_digits :: list(),
    preferred_international_prefix :: list(),
    international_prefix :: list(),
    national_prefix :: list(),
    national_prefix_for_parsing :: list(),
    national_prefix_transform_rule :: list(),
    national_prefix_formatting_rule :: list(),
    national_prefix_optional_when_formatting :: binary(),
    carrier_code_formatting_rule :: list(),
    mobile_number_portable_region :: binary()
}).

%% Necessary elements of the mobile child element in the phonenumbermetadata xml file.
-record(mobile,
{
    national_lengths :: list(),
    local_only_lengths :: list(),
    pattern :: list()
}).

%% Record to hold all the necessary metadata about a region.
-record(region_metadata,
{
    id :: binary(),
    attributes = #attributes{},
    mobile :: #mobile{}
}).

%% Type of country code source.
-type(countryCodeSource() :: 'fromNumberWithPlusSign'
                      | 'fromNumberWithIdd'
                      | 'fromNumberWithoutPlusSign'
                      | 'fromDefaultCountry'
                      | 'unspecified'
).

%% Record to hold all the necessary information about a phone_number as state when processing it.
-record(phone_number_state,
{
    country_code :: list(),
    national_number :: list(),
    phone_number :: list(),
    raw :: list(),
    country_code_source :: countryCodeSource()
}).
