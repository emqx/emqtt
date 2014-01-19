%
% NOTICE: copy from rabbitmq mqtt-adaper
%

%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2012 VMware, Inc.  All rights reserved.
%%

-define(PROTOCOL_VERSION, "MQTT/3.1").                                                 

-define(MQTT_PROTO_MAJOR, 3).
-define(MQTT_PROTO_MINOR, 1).

%% frame types

-define(CONNECT,      1).
-define(CONNACK,      2).
-define(PUBLISH,      3).
-define(PUBACK,       4).
-define(PUBREC,       5).
-define(PUBREL,       6).
-define(PUBCOMP,      7).
-define(SUBSCRIBE,    8).
-define(SUBACK,       9).
-define(UNSUBSCRIBE, 10).
-define(UNSUBACK,    11).
-define(PINGREQ,     12).
-define(PINGRESP,    13).
-define(DISCONNECT,  14).

%% connect return codes

-define(CONNACK_ACCEPT,      0).
-define(CONNACK_PROTO_VER,   1). %% unacceptable protocol version
-define(CONNACK_INVALID_ID,  2). %% identifier rejected
-define(CONNACK_SERVER,      3). %% server unavailable
-define(CONNACK_CREDENTIALS, 4). %% bad user name or password
-define(CONNACK_AUTH,        5). %% not authorized

%% qos levels

-define(QOS_0, 0).
-define(QOS_1, 1).
-define(QOS_2, 2).

-record(mqtt_frame_fixed,
	{type   = 0                       :: non_neg_integer(),
	 dup    = 0                       :: non_neg_integer(),
	 qos    = 0                       :: non_neg_integer(),
	 retain = 0                       :: non_neg_integer() }).

-record(mqtt_frame_connect,  
	{client_id   = <<>>               :: binary(),
	 proto_ver   = ?MQTT_PROTO_MAJOR  :: integer(),
	 username    = undefined          :: undefined | binary(),
	 password    = undefined          :: undefined | binary(),      
	 will_retain = false              :: boolean(),
	 will_qos    = false              :: boolean(),
	 will_flag   = false              :: boolean(),
	 clean_sess  = false              :: boolean(),
	 keep_alive  = false              :: boolean(),
	 will_topic  = undefined          :: undefined | binary(),
	 will_msg    = undefined          :: undefined | binary() }).

-record(mqtt_frame, 
	{fixed                            :: #mqtt_frame_fixed{},
	 variable                         :: #mqtt_frame_connect{},
	 payload                          :: binary() }).

-record(mqtt_frame_connack,  
	{return_code                      :: non_neg_integer() }).

-record(mqtt_frame_publish,
	{topic_name                       :: binary(),
	 message_id                       :: non_neg_integer() }).

-record(mqtt_frame_subscribe,
	{message_id                       :: non_neg_integer(),
	 topic_table                      :: list() }).

-record(mqtt_frame_suback,
	{message_id                       :: non_neg_integer(),
	 qos_table = []                   :: list()}).

-record(mqtt_topic,
	{name                             :: binary(),
	 qos                              :: non_neg_integer() }).

-record(mqtt_frame_other,
	{other                            :: any()}).

-record(mqtt_msg,
	{retain = false                   :: boolean(),
	 qos = 0                          :: non_neg_integer(),
	 topic                            :: binary(),
	 dup = 0                          :: non_neg_integer(),
	 message_id                       :: undefined | non_neg_integer(),
	 payload                          :: binary() }).


