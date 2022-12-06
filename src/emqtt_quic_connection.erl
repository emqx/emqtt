%%--------------------------------------------------------------------
%% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-module(emqtt_quic_connection).

-ifndef(BUILD_WITHOUT_QUIC).

-include_lib("quicer/include/quicer.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include("logger.hrl").

%% Callback init
-export([ init/1 ]).

%% Connection Callbacks
-export([ new_conn/3
        , connected/3
        , transport_shutdown/3
        , shutdown/3
        , closed/3
        , local_address_changed/3
        , peer_address_changed/3
        , streams_available/3
        , peer_needs_streams/3
        , nst_received/3
        , new_stream/3
        ]).

-define(LOG(Level, Msg, Meta, State),
        ?SLOG(Level, Meta#{msg => Msg, clientid => maps:get(clientid, State)}, #{})).

-type cb_ret() :: gen_statem:event_handler_result().
-type cb_data() :: emqtt_quic:cb_data().
-type connection_handle() :: quicer:connected_handle().

%% Not in use.
init(ConnOpts) when is_list(ConnOpts) ->
    init(maps:from_list(ConnOpts));
init(#{stream_opts := SOpts} = S) when is_list(SOpts) ->
    init(S#{stream_opts := maps:from_list(SOpts)});
init(ConnOpts) when is_map(ConnOpts) ->
    {ok, ConnOpts}.

-spec closed(connection_handle(), quicer:conn_closed_props(), cb_data()) -> cb_ret().
closed(_Conn, #{} = _Flags, #{state_name := waiting_for_connack, reconnect := true} =  S) ->
    ?LOG(error, "QUIC_connection_closed_reconnect", #{}, S),
    keep_state_and_data;
closed(_Conn, #{} = _Flags, #{state_name := _Other} = S)->
    ?LOG(error, "QUIC_connection_closed", #{}, S),
    %% @TODO why not stop?
    {stop, {shutdown, conn_closed}, S}.

-spec new_conn(connection_handle(), quicer:conn_closed_props(), cb_data()) -> cb_ret().
 new_conn(_Conn, #{version := _Vsn}, #{stream_opts := _SOpts} = _S) ->
    {stop, not_server}.

-spec nst_received(connection_handle(), binary(), cb_data()) -> cb_ret().
nst_received(_Conn, Ticket, #{clientid := Cid} = S) when is_binary(Ticket) ->
    catch ets:insert(quic_clients_nsts, {Cid, Ticket}),
    {keep_state, S}.

-spec new_stream(quicer:stream_handle(), quicer:new_stream_props(), cb_data()) -> cb_ret().
%% handles stream when there is no stream acceptors.
new_stream(_Stream, #{is_orphan := true} = _StreamProps,
           %% @TODO put conn ?
           #{conn := _Conn, streams := _Streams, stream_opts := _SOpts} = _CBState) ->
    %% @TODO here we could only spawn new server
    %% Spawn new stream
    {stop, unimpl}.

-spec shutdown(connection_handle(), quicer:error_code(), cb_data()) -> cb_ret().
shutdown(_Conn, _ErrorCode, #{state_name := waiting_for_connack, reconnect := true} = _S) ->
    keep_state_and_data;
shutdown(Conn, _ErrorCode, #{reconnect := true}) ->
    quicer:async_shutdown_connection(Conn, 0, 0),
    %% @TODO how to reconnect here?
    {keep_state_and_data, {next_event, info, {quic_closed, Conn}}};
shutdown(Conn, ErrorCode, S) ->
    ok = quicer:async_close_connection(Conn),
    ?LOG(info, "QUIC_peer_conn_shutdown", #{error_code => ErrorCode}, S),
    %% TCP return {shutdown, closed}
    case ErrorCode of
        success ->
            %% @TODO we should expect quicer/EMQX to send a custom error code instead.
            %% {stop, normal, S}.
            {stop, {shutdown, normal}, S};
        _Other ->
            {stop, {shutdown, ErrorCode}, S}
    end.

-spec transport_shutdown(connection_handle(), quicer:transport_shutdown_info(), cb_data())
                        -> cb_ret().
transport_shutdown(_C, DownInfo, S) ->
    ?LOG(error, "QUIC_transport_shutdown", #{down_info => DownInfo}, S),
    keep_state_and_data.

-spec peer_address_changed(connection_handle(), quicer:quicer_addr(), cb_data()) -> cb_ret().
peer_address_changed(_C, _NewAddr, _S) ->
    keep_state_and_data.

-spec local_address_changed(connection_handle(), quicer:quicer_addr(), cb_data()) -> cb_ret().
local_address_changed(_C, _NewAddr, _S) ->
    keep_state_and_data.

-spec streams_available(connection_handle(), quicer:streams_available_props(), cb_data())
                       -> cb_ret().
streams_available(_C, #{ unidi_streams := UnidirCnt
                       , bidi_streams := BidirCnt }, S) ->
    {keep_state, S#{ unidi_streams => UnidirCnt
                   , bidi_streams => BidirCnt}}.

%% @doc May integrate with App flow control
-spec peer_needs_streams(connection_handle(), undefined, cb_data()) -> cb_ret().
peer_needs_streams(_C, undefined, S) ->
    {ok, S}.

-spec connected(connection_handle(), quicer:connected_props(), cb_data()) -> cb_ret().
%% handles async 0-RTT connect
connected(_Connecion, #{ is_resumed := true }, #{state_name := waiting_for_connack} = _S) ->
    keep_state_and_data;
connected(_Connecion, _Props, _S) ->
    keep_state_and_data.
-else.
%% BUILD_WITHOUT_QUIC
-endif.
