%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%% Common data for all the group tests
%%% @end
%%% Created : 17. Jul 2020 2:36 PM
%%%-------------------------------------------------------------------

-define(UID1, <<"1000000000000000001">>).
-define(UID2, <<"1000000000000000002">>).
-define(UID3, <<"1000000000000000003">>).
-define(UID4, <<"1000000000000000004">>).
-define(UID5, <<"1000000000000000005">>).
-define(UID6, <<"1000000000000000006">>). % Does not exist
-define(UID7, <<"1000000000000000007">>). % Does not exist
-define(UID8, <<"1000000000000000008">>). % Will be deleted

-define(PHONE1, <<"12065550001">>).
-define(PHONE2, <<"12065550002">>).
-define(PHONE3, <<"12065550003">>).
-define(PHONE4, <<"12065550004">>).
-define(PHONE5, <<"12065550005">>).

-define(NAME1, <<"TUser1">>).
-define(NAME2, <<"TUser2">>).
-define(NAME3, <<"TUser3">>).
-define(NAME4, <<"TUser4">>).
-define(NAME5, <<"TUser5">>).

-define(UA, <<"HalloApp/Android1.0">>).

-define(MSG_ID1, <<"MessageId1">>).

-define(CAMPAIGN_ID, <<>>).

-define(TS1, 1600000001000).
-define(TS2, 1600000002000).
-define(TS3, 1600000003000).
-define(TS4, 1600000004000).
-define(TS5, 1600000005000).

-define(US_IP, <<"73.223.182.178">>).
-define(DE_IP, <<"79.228.247.87">>).
-define(RU_IP, <<"5.18.179.9">>).
-define(ID_IP, <<"123.253.235.113">>).
-define(SA_IP, <<"94.99.177.223">>).
-define(BR_IP, <<"191.136.147.46">>).

%% TODO(murali@): base64 encode these keys.
-define(KEYPAIR1, {kp,dh25519,
    <<16,229,224,148,125,119,38,150,165,163,251,242,100,233,7,
      247,56,24,75,194,164,92,115,237,42,162,214,176,97,107,
      121,74>>,
    <<81,123,93,125,74,103,251,33,122,113,71,177,192,112,49,
      45,37,49,209,209,222,62,134,44,236,219,47,138,6,231,10,
      76>>}).
-define(SPUB1, <<"UXtdfUpn+yF6cUexwHAxLSUx0dHePoYs7NsvigbnCkw=">>).

-define(KEYPAIR2, {kp,dh25519,
    <<64,154,34,119,38,188,227,255,180,143,129,87,55,98,66,48,
      23,106,53,223,188,232,60,119,4,46,27,172,180,38,43,103>>,
    <<10,126,112,31,249,167,68,58,16,54,134,84,111,232,135,
      67,198,78,42,162,198,73,107,82,96,196,84,79,242,67,48,
      118>>}).
-define(SPUB2, <<"Cn5wH/mnRDoQNoZUb+iHQ8ZOKqLGSWtSYMRUT/JDMHY=">>).


-define(KEYPAIR3, {kp,dh25519,
    <<24,119,240,4,183,21,229,46,98,102,54,45,6,191,76,141,
      240,139,49,20,162,228,195,5,27,126,19,245,221,194,102,
      117>>,
    <<176,44,89,52,60,198,236,157,216,59,99,139,133,49,149,
      159,17,203,253,132,57,125,87,22,195,235,209,49,29,98,
      212,110>>}).
-define(SPUB3, <<"sCxZNDzG7J3YO2OLhTGVnxHL/YQ5fVcWw+vRMR1i1G4=">>).

-define(KEYPAIR4, {kp,dh25519,
    <<56,200,53,53,116,221,217,44,223,100,247,19,184,158,69,
      230,48,106,148,49,212,192,228,53,112,161,109,154,78,138,
      115,66>>,
    <<151,69,214,131,71,144,152,84,56,111,228,83,206,236,169,
      145,232,30,56,68,219,174,28,195,245,100,252,23,47,62,
      174,24>>}).
-define(SPUB4, <<"l0XWg0eQmFQ4b+RTzuypkegeOETbrhzD9WT8Fy8+rhg=">>).

-define(KEYPAIR5, {kp,dh25519,
    <<120,175,252,158,110,238,9,195,20,122,242,21,52,148,148,
      167,162,147,101,243,182,144,100,177,90,99,1,129,42,45,
      222,116>>,
    <<139,177,180,235,128,67,74,103,21,62,106,88,188,28,227,
      114,10,36,241,129,29,68,238,57,91,91,225,178,192,84,
      158,27>>}).
-define(SPUB5, <<"i7G064BDSmcVPmpYvBzjcgok8YEdRO45W1vhssBUnhs=">>).

-define(KEYPAIR6, {kp,dh25519,
    <<56,160,151,17,105,111,248,159,224,242,238,129,31,21,217,
      198,139,213,19,253,57,171,170,114,255,224,230,144,154,
      99,151,95>>,
    <<146,59,45,49,159,43,187,135,206,26,224,175,190,38,66,
      54,142,67,202,240,184,228,135,199,84,67,66,233,10,187,
      119,80>>}).
-define(SPUB6, <<"kjstMZ8ru4fOGuCvviZCNo5DyvC45IfHVENC6Qq7d1A=">>).

-define(CALLID1, <<"kjstMZ8ru4fOGuCvviZ">>).

-define(USERNAME1, <<"username1">>).
