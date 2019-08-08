-module(test_worker).
-behaviour(gen_server).

-export([start_link/0, start_link/1, init/1, terminate/2, handle_call/3, handle_cast/2]).

start_link() ->
    gen_server:start_link(?MODULE, [], []).

start_link(_) ->
    gen_server:start_link(?MODULE, [], []).

init(_)->
    {ok, nil}.

terminate(_Reason, _)->
    ok.

handle_call(test, _, State)->
    {reply, ok, State}.

handle_cast(_, State)->
    {noreply, State}.

