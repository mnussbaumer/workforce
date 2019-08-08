-module(workforce_supervisor).
-behaviour(supervisor).

-include("workforce_shared.hrl").

-export([start_link/1, init/1, create_local_ets/1]).

-export_type([name/0, workforce_config/0]).

-spec start_link(#{worker := {atom(), atom(), list()}} | {atom(), atom(), list()}) -> {ok, pid()} | {error, term()}.
start_link({_M, _F, _A} = MFA) -> start_link(#{worker => MFA});
start_link(#{worker := {_,_,_}} = Config) ->
    #{sup_name := Sup_name} = N_config = maps:merge(?DEFAULT_CONFIG, Config),
    supervisor:start_link(Sup_name, ?MODULE, N_config).

-spec init(Config :: workforce_config()) -> {ok, {supervisor:sup_flags(), list(supervisor:child_spec())}}.
init(#{pool_name := Pool, watcher_name := Watcher, worker := {_,_,_}} = Config)->
    
    case whereis(?ETS_HOLDER) of
        undefined ->  create_ets();
        _ -> ?ETS_HOLDER ! {register, self()}
    end,
    
    Childs = [
              #{id => Watcher, start => {workforce_watcher, start_link, [Config]}, shutdown => 25000},
              #{id => Pool, start => {workforce, start_link, [Config]}, shutdown => 25000}
             ],
    
    {ok, {#{strategy => one_for_all, intensity => 3, period => 60}, Childs}}.

    

create_ets() ->
    register(?ETS_HOLDER, spawn(?MODULE, create_local_ets, [[self()]])).

create_local_ets([Pid] = Pids) ->
    ets:new(?ETS_NAME, [public, named_table, {read_concurrency, true}]),
    monitor(process, Pid),
    holder_loop(Pids).

holder_loop([]) ->
    receive
        {register, Pid} -> 
            monitor(process, Pid),
            holder_loop([Pid])
    after 1500 -> die
    end;

holder_loop(Pids) ->
    receive
        {'DOWN', _, _, Pid, _} -> holder_loop(lists:delete(Pid, Pids));
        {register, Pid} -> 
            monitor(process, Pid),
            holder_loop([Pid | Pids]);

        _ -> holder_loop(Pids)
    end.
            
