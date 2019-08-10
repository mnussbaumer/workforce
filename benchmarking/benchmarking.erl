-module(benchmarking).

-export([trasher/3, start/0, start_q/3, start_p/3, keep_track/6]).

-define(POOLBOY, [
                  {name, {local, worker}},
                  {worker_module, test_worker},
                  {size, 25},
                  {max_overflow, 25}
                 ]
       ).

-define(TIMEOUT, 10000).
-define(CYCLES, 1000).
-define(REQUESTS, 200).
-define(AFTER_CHECKIN_SLEEP, 50).
-define(FORCE_ENQUEUE, false).

start()->
    register(tests, spawn(fun() ->
                          workforce_supervisor:start_link(#{worker => {test_worker, start_link, []}, max_queue => 0, default_workers => 25, max_workers => 50}),
                          pbs:start_link(?POOLBOY),
                          receive
                              {exit} -> ok
                          end
                  end)).

trasher(Type, Interval, Rounds)->
    Self = self(),
    Pid = spawn(fun() -> wait_results(Self, Type, Rounds, Rounds, []) end),
    trasher(Type, Interval, Rounds, Pid),
    receive
        finished -> ok
    end.      
                                   
trasher(_, _, 0, _) -> ok;
trasher(workforce, Interval, Rounds, Pid)->
    start_q(?CYCLES, ?REQUESTS, Pid),
    timer:sleep(Interval),
    trasher(workforce, Interval, Rounds - 1, Pid);
trasher(poolboy, Interval, Rounds, Pid) ->
    start_p(?CYCLES, ?REQUESTS, Pid),
    timer:sleep(Interval),
    trasher(poolboy, Interval, Rounds - 1, Pid).

wait_results(Self, Type, Rounds, 0, Acc) ->
    {TotalC, TotalF, TotalTime} = lists:foldl(fun({C, F, Time}, {Ct, Ft, Timet}) ->
                              {C + Ct, F + Ft, Time + Timet}
                      end, {0, 0, 0}, Acc),
    io:format("~p~n OK: ~p ||| Failed: ~p~n AvgOK: ~p ||| AvgFailed: ~p ~n Total Time: ~p ||| Avg/Run: ~p~n", [Type, TotalC, TotalF, round(TotalC / Rounds), round(TotalF / Rounds), TotalTime, (TotalTime / Rounds)]),
    Self ! finished;

wait_results(Self, Type, Rounds, N, Acc) ->
    receive 
        {finished, Results} -> wait_results(Self, Type, Rounds, N - 1, [Results | Acc])
    end.

start_q(Cycles, Iterations, WPid) ->
    Pid = whereis(workforce),
    Time = erlang:system_time(millisecond),
    Receiver = spawn(?MODULE, keep_track, [Time, 0, 0, Cycles * Iterations, WPid, workforce]),
    start_test_q(Pid, Receiver, Cycles, Iterations).

start_test_q(Pid, Receiver, 0, Iterations) -> iterate_q(Pid, Receiver, Iterations);
start_test_q(Pid, Receiver, Cycles, Iterations) ->
    spawn(fun() -> iterate_q(Pid, Receiver, Iterations) end),
    start_test_q(Pid, Receiver, Cycles - 1, Iterations).

iterate_q(_, _, 0) -> ok;
iterate_q(Pid, Receiver, N) ->
    spawn(fun() ->
                  case workforce:checkout(Pid, ?TIMEOUT, ?FORCE_ENQUEUE) of
                      {ok, W_pid} ->
                          ok = gen_server:call(W_pid, test),
                          Receiver ! ok,
                          timer:sleep(?AFTER_CHECKIN_SLEEP),
                          workforce:checkin(Pid, W_pid);
                      _Error ->
                          Receiver ! failed
                  end
          end),
    iterate_q(Pid, Receiver, N - 1).

start_p(Cycles, Iterations, WPid) ->
    Pid = whereis(worker),
    Time = erlang:system_time(millisecond),
    Receiver = spawn(?MODULE, keep_track, [Time, 0, 0, Cycles * Iterations, WPid, poolboy]),
    start_test_p(Pid, Receiver, Cycles, Iterations).

start_test_p(Pid, Receiver, 0, Iterations) -> iterate_p(Pid, Receiver, Iterations);
start_test_p(Pid, Receiver, Cycles, Iterations) ->
    spawn(fun() -> iterate_p(Pid, Receiver, Iterations) end),
    start_test_p(Pid, Receiver, Cycles - 1, Iterations).

iterate_p(_, _, 0) -> ok;
iterate_p(Pid, Receiver, N) ->
    spawn(fun() ->
                  case poolboy:checkout(Pid, ?FORCE_ENQUEUE, ?TIMEOUT) of
                      W_pid when is_pid(W_pid) ->
                          ok = gen_server:call(W_pid, test),
                          Receiver ! ok,
                          timer:sleep(?AFTER_CHECKIN_SLEEP),
                          poolboy:checkin(Pid, W_pid);
                      _Error ->
                          Receiver ! failed
                  %catch
                  %    _:_ ->
                  %        Receiver ! failed
                  end
          end),
    iterate_p(Pid, Receiver, N - 1).


keep_track(Time, C, F, T, Pid, What) when C + F == T ->
    Time_now = erlang:system_time(millisecond),
    Total_time = (Time_now - Time) / 1000,
    io:format("~n##### ~p~n", [What]),
    io:format("OK: ~p ----- Failed: ~p~n", [C, F]), 
    io:format("Elapsed: ~p~n", [Total_time]),
    Pid ! {finished, {C, F, Total_time}};

keep_track(Time, C, F, T, Pid, What) ->
    Time_now = erlang:system_time(millisecond),
    receive
        ok ->
            keep_track(Time, C + 1, F, T, Pid, What);
        failed  ->
            keep_track(Time, C, F + 1, T, Pid, What)
    after
        25000 ->
            Total_time = (Time_now - Time) / 1000,
            io:format("~n##### ~p~n", [What]),
            io:format("OK: ~p ----- Failed: ~p~n", [C, F]), 
            io:format("Elapsed: ~p~n", [Total_time]),
            Pid ! {finished, {C, F, Total_time}}
    end.
