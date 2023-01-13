%%-------------------------------------------------------------------------
%% Copyright (c) 2021-2023 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%-------------------------------------------------------------------------

-module(emqtt_quic).
-ifndef(BUILD_WITHOUT_QUIC).
-include("logger.hrl").
-include("emqtt.hrl").
-include_lib("quicer/include/quicer.hrl").


-define(LOG(Level, Msg, Meta, State),
        ?SLOG(Level, Meta#{msg => Msg, clientid => maps:get(clientid, State)}, #{})).

-export([ connect/4
        , send/2
        , recv/2
        , close/1
        , open_connection/0
        ]).

-export([ setopts/2
        , getstat/2
        , sockname/1
        ]).

-export([init_state/1]).

%% state machine callback1
-export([handle_info/3]).

-export_type([ mqtt_packets/0
             , quic_msg/0
             , quic_sock/0
             ]).

-type cb_data() :: #{ clientid := binary()
                    , parse_state := emqtt_frame:parse_state()
                    , data_stream_socks := [quic_sock()]
                    , control_stream_sock := undefined | quic_sock()
                    , stream_opts := map()
                    , state_name := gen_fsm:state_name()
                    , is_local => boolean()
                    , is_unidir => boolean()
                    , quic_conn_cb => module()
                    , quic_stream_cb => module()
                    , reconnect => boolean()
                    , peer_bidi_stream_count => non_neg_integer()
                    , peer_unidi_stream_count => non_neg_integer()
                    }.
-type mqtt_packets() :: [#mqtt_packet{}] | [].
-type quic_sock() :: {quic, quicer:connection_handle(), quicer:stream_handle()}.
-type quic_msg() :: {quic, atom() | binary(), Resource::any(), Props::any()}.


-spec init_state(map()) -> cb_data().
init_state(#{ state_name := _S} = OldData) ->
    OldData;
init_state(Data) when is_map(Data) ->
    Data#{ quic_conn_cb => emqtt_quic_connection
         , quic_stream_cb => emqtt_quic_stream
         , state_name => init
         , is_local => true %% @TODO per stream
         , is_unidir => false %% @TODO per stream
         }.

-spec handle_info(quic_msg(), gen_statem:state(), cb_data()) -> gen_statem:handle_event_result().
%% Handle Quic Data
handle_info({quic, Data, Stream, Props}, StateName, #{quic_stream_cb := StreamCB} = CBState)
  when is_binary(Data) ->
    StreamCB:handle_stream_data(Stream, Data, Props, CBState#{state_name := StateName} );
handle_info({quic, Event, Connection, Props}, StateName, #{quic_conn_cb := ConnCB} = CBState)
  when connected =:= Event orelse
       transport_shutdown =:= Event orelse
       shutdown =:= Event orelse
       closed =:= Event orelse
       local_address_changed =:= Event orelse
       peer_address_changed =:= Event orelse
       streams_available =:= Event orelse
       peer_needs_streams =:= Event orelse
       nst_received =:= Event ->
    ConnCB:Event(Connection, Props, CBState#{state_name := StateName});
handle_info({quic, Event, Stream, Props}, StateName, #{quic_stream_cb := StreamCB} = CBState)
  when start_completed =:= Event orelse
       send_complete =:= Event orelse
       peer_send_shutdown =:= Event orelse
       peer_send_aborted =:= Event orelse
       peer_receive_aborted =:= Event orelse
       send_shutdown_complete =:= Event orelse
       stream_closed =:= Event orelse
       peer_accepted =:= Event orelse
       passive =:= Event ->
    StreamCB:Event(Stream, Props, CBState#{state_name := StateName}).

open_connection() ->
    quicer:open_connection().

connect(Host, Port, Opts, Timeout) ->
    KeepAlive =  proplists:get_value(keepalive, Opts, 60),
    ConnOpts = [ {alpn, ["mqtt"]}
               , {idle_timeout_ms, timer:seconds(KeepAlive * 3)}
               , {peer_unidi_stream_count, 1}
               , {peer_bidi_stream_count, 1}
               , {verify, none}
               , {quic_event_mask, ?QUICER_CONNECTION_EVENT_MASK_NST}
               % , {send_idle_timeout_ms,  1000}
               % , {disconnect_timeout_ms, 300000}
               %% uncomment for decrypt wireshark trace
               %%, {sslkeylogfile, "/tmp/SSLKEYLOGFILE"}
               | Opts] ++ local_addr(Opts),
    case lists:keymember(nst, 1, ConnOpts) of
        true -> do_0rtt_connect(Host, Port, ConnOpts);
        false -> do_1rtt_connect(Host, Port, ConnOpts, Timeout)
    end.

do_0rtt_connect(Host, Port, ConnOpts) ->
    IsConnOpened = proplists:is_defined(handle, ConnOpts),
    case quicer:async_connect(Host, Port, ConnOpts) of
        {ok, Conn} when not IsConnOpened ->
            case quicer:start_stream(Conn, #{active => 1}) of
                {ok, Stream} ->
                    {ok, {quic, Conn, Stream}};
                {error, Type, Info} ->
                    {error, {Type, Info}};
                Error ->
                    Error
            end;
        {ok, _Conn} = Res ->
            skip;
        {error, Type, Info} ->
            {error, {Type, Info}};
        {error, _} = Error ->
            Error
    end.

do_1rtt_connect(Host, Port, ConnOpts, Timeout) ->
    IsConnOpened = proplists:is_defined(handle, ConnOpts),
    case quicer:connect(Host, Port, ConnOpts, Timeout) of
        {ok, Conn} when not IsConnOpened ->
            case quicer:start_stream(Conn, #{active => 1}) of
                {ok, Stream} ->
                    {ok, {quic, Conn, Stream}};
                {error, Type, Info} ->
                    {error, {Type, Info}};
                Error ->
                    Error
            end;
        {ok, _Conn} = Res ->
            skip;
        {error, transport_down, Reason} ->
            {error, {transport_down, Reason}};
        {error, _} = Error ->
            Error
    end.

send({quic, _Conn, Stream}, Bin) ->
    send(Stream, Bin);
send(Stream, Bin) ->
    %% Use async here because we could send before start the connecion.
    case quicer:async_send(Stream, Bin) of
        {ok, _Len} ->
            ok;
        {error, ErrorType, Reason} ->
            {error, {ErrorType, Reason}};
        Other ->
            Other
    end.

recv({quic, _Conn, Stream}, Count) ->
    quicer:recv(Stream, Count).

getstat({quic, Conn, _Stream}, Options) ->
    quicer:getstat(Conn, Options).

setopts({quic, _Conn, Stream}, Opts) ->
    [ ok = quicer:setopt(Stream, Opt, OptV)
      || {Opt, OptV} <- Opts ],
    ok.

close({quic, Conn, Stream}) ->
    %% gracefully shutdown the stream to flush all the msg in sndbuf.
    quicer:shutdown_stream(Stream, 500),
    quicer:close_connection(Conn, ?QUIC_CONNECTION_SHUTDOWN_FLAG_NONE, 0, 500).

sockname({quic, Conn, _Stream}) ->
    quicer:sockname(Conn).

local_addr(SOpts) ->
    case { proplists:get_value(port, SOpts, 0),
           proplists:get_value(ip, SOpts, undefined)} of
        {0, undefined} ->
            [];
        {Port, undefined} ->
            [{param_conn_local_address, ":" ++ integer_to_list(Port)}];
        {Port, IpAddr} when is_tuple(IpAddr) ->
            [{param_conn_local_address, inet:ntoa(IpAddr) ++ ":" ++integer_to_list(Port)}]
    end.

-else.
%% BUILD_WITHOUT_QUIC
-endif.
