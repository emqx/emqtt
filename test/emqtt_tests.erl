%%--------------------------------------------------------------------
%% Copyright (c) 2020-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

%% eunit tests for `emqtt'. Named `emqtt_tests' so it is auto-discovered
%% when running eunit against the `emqtt' module.
-module(emqtt_tests).

-include_lib("eunit/include/eunit.hrl").

%%--------------------------------------------------------------------
%% connack_properties_to_merge/1
%%
%% Regression coverage: MQTT v5 property identifiers 0x21 (Receive
%% Maximum), 0x22 (Topic Alias Maximum) and 0x27 (Maximum Packet Size)
%% appear in both CONNECT and CONNACK with OPPOSITE directional meaning.
%% The broker's CONNACK value must NOT overwrite the client's CONNECT
%% value in `State#state.properties'.
%%--------------------------------------------------------------------

%% Directional properties (broker's CONNACK value applies to
%% client -> broker direction, NOT a replacement for the client's CONNECT
%% value) MUST be dropped before merging into the client-side property
%% map.
connack_properties_to_merge_drops_directional_props_test() ->
    BrokerProps = #{'Receive-Maximum'     => 10,
                    'Topic-Alias-Maximum' => 5,
                    'Maximum-Packet-Size' => 1024,
                    'Server-Keep-Alive'   => 30},
    Merged = emqtt:connack_properties_to_merge(BrokerProps),
    ?assertNot(maps:is_key('Receive-Maximum', Merged)),
    ?assertNot(maps:is_key('Topic-Alias-Maximum', Merged)),
    ?assertNot(maps:is_key('Maximum-Packet-Size', Merged)),
    ?assertEqual(#{'Server-Keep-Alive' => 30}, Merged).

%% Broker-authoritative / CONNACK-only properties MUST be kept so they
%% can override or augment the client-side property map.
connack_properties_to_merge_keeps_broker_authoritative_props_test() ->
    BrokerProps = #{'Assigned-Client-Identifier'        => <<"c1">>,
                    'Server-Keep-Alive'                 => 30,
                    'Session-Expiry-Interval'           => 60,
                    'Maximum-QoS'                       => 1,
                    'Retain-Available'                  => 0,
                    'Wildcard-Subscription-Available'   => 1,
                    'Subscription-Identifier-Available' => 1,
                    'Shared-Subscription-Available'     => 1,
                    'Reason-String'                     => <<"ok">>,
                    'Response-Information'              => <<"resp/">>,
                    'Server-Reference'                  => <<"other:1883">>,
                    'Authentication-Method'             => <<"SCRAM-SHA-1">>,
                    'Authentication-Data'               => <<"data">>,
                    'User-Property'                     => [{<<"k">>, <<"v">>}]},
    ?assertEqual(BrokerProps, emqtt:connack_properties_to_merge(BrokerProps)).

%% Simulate the actual merge in `waiting_for_connack': the client's
%% CONNECT-side directional properties must survive the merge with the
%% broker's CONNACK properties.
connack_merge_preserves_client_directional_props_test() ->
    %% Client declared these limits in CONNECT (they govern
    %% broker -> client traffic, e.g. how big a packet the client can
    %% parse, what topic aliases the broker may use when publishing to
    %% the client, how many concurrent unacked QoS>0 PUBLISHes the broker
    %% may push to us).
    ClientProps = #{'Receive-Maximum'     => 32,
                    'Topic-Alias-Maximum' => 16,
                    'Maximum-Packet-Size' => 65536},
    %% Broker returned these limits in CONNACK (they govern
    %% client -> broker traffic). They share property identifiers with
    %% the CONNECT ones but mean something different and must not
    %% overwrite the client's view.
    BrokerProps = #{'Receive-Maximum'     => 4,
                    'Topic-Alias-Maximum' => 2,
                    'Maximum-Packet-Size' => 1024,
                    'Server-Keep-Alive'   => 30},
    Merged = maps:merge(ClientProps,
                        emqtt:connack_properties_to_merge(BrokerProps)),
    ?assertEqual(32,    maps:get('Receive-Maximum',     Merged)),
    ?assertEqual(16,    maps:get('Topic-Alias-Maximum', Merged)),
    ?assertEqual(65536, maps:get('Maximum-Packet-Size', Merged)),
    %% Broker-only property still comes through.
    ?assertEqual(30,    maps:get('Server-Keep-Alive',   Merged)).

%% An empty broker properties map is a no-op.
connack_properties_to_merge_empty_test() ->
    ?assertEqual(#{}, emqtt:connack_properties_to_merge(#{})).
