%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2012-2016 eMQTT.IO, All Rights Reserved.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc emqttc socket keepalive.
%%%
%%% @author Feng Lee <feng@emqtt.io>
%%%-----------------------------------------------------------------------------

-module(emqttc_keepalive).

-record(keepalive, {socket,
                    stat_name,
                    stat_val = 0,
                    timeout_sec,
                    timeout_msg,
                    timer_ref}).

-opaque keepalive() :: #keepalive{} | undefined.

-export_type([keepalive/0]).

%% API
-export([new/3, start/1, restart/1, resume/1, cancel/1]).

%% @doc Create a KeepAlive.
-spec new({Socket, StatName}, TimeoutSec, TimeoutMsg) -> KeepAlive when
    Socket        :: inet:socket() | ssl:sslsocket(),
    StatName      :: recv_oct | send_oct,
    TimeoutSec    :: non_neg_integer(),
    TimeoutMsg    :: tuple(),
    KeepAlive     :: keepalive().
new({_Socket, _StatName}, 0, _TimeoutMsg) ->
    undefined;
new({Socket, StatName}, TimeoutSec, TimeoutMsg) when TimeoutSec > 0 ->
    #keepalive{socket      = Socket,
               stat_name   = StatName,
               timeout_sec = TimeoutSec,
               timeout_msg = TimeoutMsg}.

%% @doc Start KeepAlive
-spec start(keepalive()) -> {ok, keepalive()} | {error, any()}.
start(undefined) ->
    {ok, undefined};
start(KeepAlive = #keepalive{socket = Socket, stat_name = StatName,
                             timeout_sec = TimeoutSec,
                             timeout_msg = TimeoutMsg}) ->
    case emqttc_socket:getstat(Socket, [StatName]) of
        {ok, [{StatName, StatVal}]} ->
            Ref = erlang:send_after(TimeoutSec*1000, self(), TimeoutMsg),
            {ok, KeepAlive#keepalive{stat_val = StatVal, timer_ref = Ref}};
        {error, Error} ->
            {error, Error}
    end.

%% @doc Restart KeepAlive
-spec restart(keepalive()) -> {ok, keepalive()} | {error, any()}.
restart(KeepAlive) -> start(KeepAlive).

%% @doc Resume KeepAlive, called when timeout.
-spec resume(keepalive()) -> timeout | {resumed, keepalive()} | {error, any()}.
resume(undefined) -> {resumed, undefined};
resume(KeepAlive = #keepalive{socket      = Socket,
                              stat_name   = StatName,
                              stat_val    = StatVal,
                              timeout_sec = TimeoutSec,
                              timeout_msg = TimeoutMsg,
                              timer_ref   = Ref}) ->
    case emqttc_socket:getstat(Socket, [StatName]) of
        {ok, [{StatName, NewStatVal}]} ->
            if
                NewStatVal =:= StatVal ->
                    timeout;
                true ->
                    cancel(Ref), %need?
                    NewRef = erlang:send_after(TimeoutSec*1000, self(), TimeoutMsg),
                    {resumed, KeepAlive#keepalive{stat_val = NewStatVal, timer_ref = NewRef}}
            end;
        {error, Error} ->
            {error, Error}
    end.

%% @doc Cancel KeepAlive.
-spec cancel(keepalive() | reference()) -> any().
cancel(undefined) ->
    ok;
cancel(#keepalive{timer_ref = Ref}) ->
    cancel(Ref);
cancel(Ref) when is_reference(Ref)->
    catch erlang:cancel_timer(Ref).

