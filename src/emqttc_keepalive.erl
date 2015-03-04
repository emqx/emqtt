%%%-----------------------------------------------------------------------------
%%% @Copyright (C) 2012-2015, Feng Lee <feng@emqtt.io>
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
%%% @doc
%%% emqttc socket keepalive.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(emqttc_keepalive).

-author("feng@emqtt.io").

-record(keepalive, {socket,
                    stat_name,
                    stat_val = 0,
                    timeout_sec,
                    timeout_msg,
                    timer_ref}).

-opaque keepalive() :: #keepalive{}.

-export_type([keepalive/0]).

%% API
-export([new/3, start/1, restart/1, resume/1, cancel/1]).

%%%-----------------------------------------------------------------------------
%% @doc
%% Create a KeepAlive.
%%
%% @end
%%%-----------------------------------------------------------------------------
-spec new({Socket, StatName}, TimeoutSec, TimeoutMsg) -> KeepAlive when
    Socket        :: inet:socket() | ssl:sslsocket(),
    StatName      :: recv_oct | send_oct,
    TimeoutSec    :: non_neg_integer(),
    TimeoutMsg    :: tuple(),
    KeepAlive     :: keepalive() | undefined.
new({_Socket, _StatName}, 0, _TimeoutMsg) ->
    undefined;
new({Socket, StatName}, TimeoutSec, TimeoutMsg) when TimeoutSec > 0 ->
    #keepalive{socket      = Socket,
               stat_name   = StatName,
               timeout_sec = TimeoutSec,
               timeout_msg = TimeoutMsg}.

%%------------------------------------------------------------------------------
%% @doc
%% Start KeepAlive.
%%
%% @end
%%------------------------------------------------------------------------------
-spec start(KeepAlive) -> KeepAlive when
    KeepAlive   :: keepalive() | undefined.
start(undefined) ->
    undefined;
start(KeepAlive = #keepalive{socket = Socket, stat_name = StatName, 
                             timeout_sec = TimeoutSec, 
                             timeout_msg = TimeoutMsg}) ->
    {ok, [{StatName, StatVal}]} = emqttc_socket:getstat(Socket, [StatName]),
    Ref = erlang:send_after(TimeoutSec*1000, self(), TimeoutMsg),
    KeepAlive#keepalive{stat_val = StatVal, timer_ref = Ref}.

%%------------------------------------------------------------------------------
%% @doc
%% Restart KeepAlive.
%%
%% @end
%%------------------------------------------------------------------------------
-spec restart(KeepAlive) -> KeepAlive when
    KeepAlive   :: keepalive() | undefined.
restart(KeepAlive) -> start(KeepAlive).

%%------------------------------------------------------------------------------
%% @doc
%% Resume KeepAlive, called when timeout.
%%
%% @end
%%------------------------------------------------------------------------------
-spec resume(KeepAlive) -> timeout | {resumed, KeepAlive} when
    KeepAlive  :: keepalive() | undefined.
resume(undefined) -> undefined;
resume(KeepAlive = #keepalive{socket      = Socket,
                              stat_name   = StatName,
                              stat_val    = StatVal,
                              timeout_sec = TimeoutSec,
                              timeout_msg = TimeoutMsg,
                              timer_ref   = Ref}) ->
    {ok, [{StatName, NewStatVal}]} = emqttc_socket:getstat(Socket, [StatName]),
    if
        NewStatVal =:= StatVal ->
            timeout;
        true ->
            cancel(Ref), %need?
            NewRef = erlang:send_after(TimeoutSec*1000, self(), TimeoutMsg),
            {resumed, KeepAlive#keepalive{stat_val = NewStatVal, timer_ref = NewRef}}
    end.

%%------------------------------------------------------------------------------
%% @doc
%% Cancel KeepAlive.
%%
%% @end
%%------------------------------------------------------------------------------
-spec cancel(keepalive() | undefined | reference()) -> any().
cancel(undefined) ->
    ok;
cancel(#keepalive{timer_ref = Ref}) ->
    cancel(Ref);
cancel(Ref) when is_reference(Ref)->
    catch erlang:cancel_timer(Ref).
