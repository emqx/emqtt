%%%-------------------------------------------------------------------
%%% @author HIROE Shin <shin@HIROE-no-MacBook-Pro.local>
%%% @copyright (C) 2014, HIROE Shin
%%% @doc
%%%
%%% @end
%%% Created : 30 Jan 2014 by HIROE Shin <shin@HIROE-no-MacBook-Pro.local>
%%%-------------------------------------------------------------------
-module(emqttc_sock_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_sock/3, terminate_sock/1]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API functions
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc Starts the supervisor
%% @end
%%--------------------------------------------------------------------
-spec start_link() -> {ok, pid()} | ignore | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%--------------------------------------------------------------------
%% @doc Starts child
%% @end
%%--------------------------------------------------------------------
-spec start_sock(ChildNo, Sock, Client) -> supervisor:start_child_ret() when
      ChildNo :: non_neg_integer(),
      Sock :: gen_tcp:socket(),
      Client :: pid().
start_sock(ChildNo, Sock, Client) ->
    ChildSpec = {{emqttc_sock, ChildNo},
		 {emqttc_sock, start_link, [Sock, Client]},
		 permanent, 2000, worker, [emqttc_sock]},
    supervisor:start_child(?SERVER, ChildSpec).

%%--------------------------------------------------------------------
%% @doc Terminate child
%% @end
%%--------------------------------------------------------------------
-spec terminate_sock(ChildNo) -> ok | {error, Error} when
      ChildNo :: non_neg_integer(),
      Error :: term().
terminate_sock(ChildNo) ->
    supervisor:terminate_child(?SERVER, {emqttc_sock, ChildNo}).

%%%===================================================================
%%% Supervisor callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Whenever a supervisor is started using supervisor:start_link/[2,3],
%% this function is called by the new process to find out about
%% restart strategy, maximum restart frequency and child
%% specifications.
%%
%% @spec init(Args) -> {ok, {SupFlags, [ChildSpec]}} |
%%                     ignore |
%%                     {error, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    RestartStrategy = one_for_one,
    MaxRestarts = 1000,
    MaxSecondsBetweenRestarts = 3600,

    SupFlags = {RestartStrategy, MaxRestarts, MaxSecondsBetweenRestarts},

    Restart = permanent,
    Shutdown = 2000,
    Type = worker,

    AChild = {'AName', {'AModule', start_link, []},
	      Restart, Shutdown, Type, ['AModule']},

    {ok, {SupFlags, [AChild]}}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
