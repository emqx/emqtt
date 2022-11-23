%%-------------------------------------------------------------------------
%% Copyright (c) 2021-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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
-module(emqtt_quic_stream).

-export([ init_handoff/4
        , new_stream/3
        , start_completed/3
        , send_complete/3
        , peer_send_shutdown/3
        , peer_send_aborted/3
        , peer_receive_aborted/3
        , send_shutdown_complete/3
        , stream_closed/3
        , peer_accepted/3
        , passive/3
        , handle_call/4
        ]).

-export([handle_stream_data/4]).

-include_lib("quicer/include/quicer_types.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").
-include("emqtt.hrl").
-include("logger.hrl").


-define(LOG(Level, Msg, Meta, State),
        ?SLOG(Level, Meta#{msg => Msg, clientid => maps:get(clientid, State)}, #{})).

-type cb_ret() :: gen_statem:event_handler_result().
-type cb_data() :: emqtt_quic:cb_data().

-spec init_handoff(stream_handle(), #{}, quicer:connection_handle(), #{}) -> cb_ret().
init_handoff(_Stream, _StreamOpts, _Conn, _Flags) ->
    %% stream owner already set while starts.
    {stop, unimpl}.

-spec new_stream(stream_handle(), quicer:new_stream_props(), cb_data()) -> cb_ret().
new_stream(_Stream, #{flags := _Flags, is_orphan := _IsOrphan}, _Conn) ->
    {stop, unimpl}.

-spec peer_accepted(stream_handle(), undefined, cb_data()) -> cb_ret().
peer_accepted(_Stream, undefined, _S) ->
    %% We just ignore it
    keep_state_and_data.

-spec peer_receive_aborted(stream_handle(), non_neg_integer(), cb_data()) -> cb_ret().
peer_receive_aborted(Stream, ErrorCode, #{is_unidir := false} = _S) ->
    %% we abort send with same reason
    quicer:async_shutdown_stream(Stream, ?QUIC_STREAM_SHUTDOWN_FLAG_ABORT, ErrorCode),
    keep_state_and_data;
peer_receive_aborted(Stream, ErrorCode, #{is_unidir := true, is_local := true} = _S) ->
    quicer:async_shutdown_stream(Stream, ?QUIC_STREAM_SHUTDOWN_FLAG_ABORT, ErrorCode),
    keep_state_and_data.

-spec peer_send_aborted(stream_handle(), non_neg_integer(), cb_data()) -> cb_ret().
peer_send_aborted(Stream, ErrorCode, #{is_unidir := false} = _S) ->
    %% we abort receive with same reason
    quicer:async_shutdown_stream(Stream, ?QUIC_STREAM_SHUTDOWN_FLAG_ABORT_RECEIVE, ErrorCode),
    keep_state_and_data;
peer_send_aborted(Stream, ErrorCode, #{is_unidir := true, is_local := false} = _S) ->
    quicer:async_shutdown_stream(Stream, ?QUIC_STREAM_SHUTDOWN_FLAG_ABORT_RECEIVE, ErrorCode),
    keep_state_and_data.

-spec peer_send_shutdown(stream_handle(), undefined, cb_data()) -> cb_ret().
peer_send_shutdown(Stream, undefined, _S) ->
    ok = quicer:async_shutdown_stream(Stream, ?QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL, 0),
    keep_state_and_data.

-spec send_complete(stream_handle(), boolean(), cb_data()) -> cb_ret().
send_complete(_Stream, false, _S) ->
    keep_state_and_data;
send_complete(_Stream, true = _IsCanceled, S) ->
    %% @TODO bump counter
    ?LOG(error, "QUIC_stream_send_canceled", #{}, S),
    keep_state_and_data.

-spec send_shutdown_complete(stream_handle(), boolean(), cb_data()) -> cb_ret().
send_shutdown_complete(_Stream, _IsGraceful, _S) ->
    keep_state_and_data.

-spec start_completed(stream_handle(), quicer:stream_start_completed_props(), cb_data())
                     -> cb_ret().
start_completed(_Stream, #{status := success, stream_id := StreamId} = Prop, S) ->
    ?LOG(debug, "QUIC_stream_start_completed", Prop, S),
    {ok, S#{stream_id => StreamId}};
start_completed(_Stream, #{status := stream_limit_reached, stream_id := _StreamId} = Prop, S) ->
    ?LOG(error, "QUIC_stream_start_failed", Prop, S),
    {stop, stream_limit_reached};
start_completed(_Stream, #{status := Other } = Prop, S) ->
    ?LOG(error, "QUIC_stream_start_failed", Prop, S),
    %% or we could retry?
    {stop, {start_fail, Other}, S}.

%% Local stream, Unidir
-spec handle_stream_data(stream_handle(), binary(), quicer:recv_data_props(), cb_data())
                        -> cb_ret().
handle_stream_data(Stream, Bin, _Flags, #{ is_local := true
                                         , control_stream_sock := {quic, Conn, _ControlStream}
                                         , parse_state := PS} = S) ->
    ?LOG(debug, "RECV_Data", #{data => Bin}, S),
    Via = {quic, Conn, Stream},
    case parse(Bin, PS, []) of
        {keep_state, NewPS, Packets} ->
            {keep_state, S#{parse_state := NewPS},
             [{next_event, cast, {P, Via} }
              || P <- lists:reverse(Packets)]};
        {stop, _} = Stop ->
            Stop
    end;
%% Remote stream
handle_stream_data(_Stream, _Bin, _Flags,
                   #{is_local := false, is_unidir := true, conn := _Conn} = _S) ->
    {stop, unimpl}.


-spec passive(stream_handle(), undefined, cb_data()) -> cb_ret().
passive(Stream, undefined, _S)->
    %% @TODO Should be called only once during the whole connecion
    quicer:setopt(Stream, active, true),
    keep_state_and_data.

-spec stream_closed(stream_handle(), stream_closed_props(), cb_data()) -> cb_ret().
stream_closed(_Stream, #{ is_conn_shutdown := _ }, #{reconnect := true}) ->
    keep_state_and_data;
stream_closed(_Stream, #{ is_conn_shutdown := IsConnShutdown
                        , is_app_closing := IsAppClosing
                        , is_shutdown_by_app := IsAppShutdown
                        , is_closed_remotely := IsRemote
                        , status := Status
                        , error := Code
                        }, _S) when is_boolean(IsConnShutdown) andalso
                                    is_boolean(IsAppClosing) andalso
                                    is_boolean(IsAppShutdown) andalso
                                    is_boolean(IsRemote) andalso
                                    is_atom(Status) andalso
                                    is_integer(Code) ->
    {stop, normal}.

handle_call(_Stream, _Request, _Opts, S) ->
    {error, unimpl, S}.

%%% Internals
-spec parse(binary(), emqtt_frame:parse_state(), emqtt_quic:mqtt_packets())
           -> emqtt_frame:parse_res().
parse(<<>>, PS, Packets) ->
    {keep_state, PS, Packets};
parse(Bin, PS, Packets) ->
    try emqtt_frame:parse(Bin, PS) of
        {ok, MQTT, BinLeft, NewPS} ->
            parse(BinLeft, NewPS, [MQTT | Packets]);
        {more, NewPS} ->
            {keep_state, NewPS, Packets}
    catch
        error:Error:ST ->
            {stop, {Error, ST}}
    end.
