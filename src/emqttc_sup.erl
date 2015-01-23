
-module(emqttc_sup).

-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type), {I, {I, start_link, []}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    Ets = ets:new(childno_db, [set, public]),

    ChildNo = {emqttc_childno, {emqttc_childno, start_link, [Ets]},
	       permanent, 2000, worker, [emqttc_childno]},

    SockSup = {emqttc_sock_sup, {emqttc_sock_sup, start_link, []},
	       permanent, 2000, supervisor, [emqttc_sock_sup]},

    SubEvent = {emqttc_event, {emqttc_event, start_link, []},
		permanent, 2000, worker, [emqttc_event]},

    {ok, { {one_for_one, 5, 10}, [ChildNo, SockSup, SubEvent]} }.

