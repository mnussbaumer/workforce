workforce
=====

Not enough resources but still need to get things done? Welcome to the Workforce - get on track and Godspeed! you! to! management!
(this introduction could use some more exclamation marks! there! fixed it!)


Workforce is a **fast**, **reliable** and **customisable** generic worker pool for Erlang/Elixir.

```erlang
    % #{
    %    sup_name => {local, workforce_supervisor},
    %    watcher_name => {local, workforce_watcher},
    %    pool_name => {local, workforce},
    %    worker => nil,
    %    default_workers => 20,
    %    max_workers => 25,
    %    max_queue => 0,
    %    hibernate_when_free => false,
    %    shrink_timeout => {5000, 10000}
    % } % defaults
    
    Config = #{worker => {my_nifty_worker, start_link, []}, default_workers => 5, max_workers => 6},
    
    {ok, _Sup_Pid} = workforce_supervisor:start_link(Config),
    
    {ok, Worker1} = workforce:checkout(workforce),
    
    Worker1 ! {work_you_lazy_bum, 1},
    receive {Worker1, done} end,
    
    workforce:checkin(workforce, Worker1).
```

___
#### Install

#### Erlang (rebar3)

```erlang
{deps, [{workforce, "0.1.0"}]}.
```

#### Elixir

Add to your deps:

```elixir
defp deps do
    [
        # ...
        {:workforce, "~> 0.1.0"}
    ]
end
```


___
#### Options

To use workforce correctly start it as part of a supervision tree and pass it a map containing at least the key `worker` set to the `{module, function, arguments_list}` that starts your worker. Optionally if you want to use the defaults you can pass directly the tuple to start_link `workforce_supervisor:start_link({module, function, args}`. To customise the options use the map form and include any of the following keys:

<ul>
    <li><b>sup_name</b>/<b>watcher_name</b>/<b>pool_name</b>: how each of the elements are going to be registered;</li>
    <li><b>default_workers</b>: Number of workers to start by default;</li>
    <li><b>max_workers</b>: Number of maximum workers, >= than default_workers, if higher, then an additional up to N = (Maximum - Default) workers will be started whenever the pooler requires to answer requests;</li>
    <li><b>max_queue</b>: If the pooler is allowed to enqueue requests when no worker is available, 0 means no, -1 means yes in an unbound queue, N > 0 means yes up to N;</li>
    <li><b>hibernate_when_free</b> - if the pooler should trigger an hibernate/gc whenever the number of available workers == the number of active workers (impacts performance);</li>
    <li><b>shrink_timeout</b> - If max_workers > than default_workers, whenever an extra worker is started how much should it wait to check if a worker is no longer necessary (the defaults are quite okey for about everything - this option is mostly to ease testing). Can be passed as a positive integer (same timeout always) or a tuple {positive_integer, positive_integer}, where the first element is the first timeout from creation, and the second is all subsequent timeouts. A worker is decomissioned when the number of Active workers is > than the Default Workers, and the Number of Available Workers is > than the Default/5, checked on the specified timeout intervals.</li>
</ul>
    
___    
### API

The workforce API has 3 different kinds of checkout interfaces for different use cases.

___
#### Regular Checkouts

This is the normal form and should be used whenever both the requester and the pooler are on the same node.

```erlang
    {ok, Worker1} = workforce:checkout(Pid_or_name_of_pool), 
    %defaults to: workforce:checkout(Pid_or_name, 5000, false)
    
    Timeout = 3000 % a positive integer or infinity, use infinity with care
    {ok, Worker2} = workforce:checkout(Pid_or_name_of_pool, Timeout),
    
    ForceEnqueue = true, % default is false, forces this request to be enqueued independently of the pooler having the queue enabled or not
    {ok, Worker3} = workforce:checkout(Pid_or_name_of_pool, 5000, true).
```

___
#### Remote Checkouts

This form should be used whenever the processes requesting work from the pooler may be on different nodes from the pooler. Underneath, if both the caller and the pooler are on the same node it uses the regular checkout, if they're not then it uses a `gen_statem:call` - this means it can raise any `call` exception and you should take that into account. This mode doesn't allow for requests to be enqueued.

```erlang
    {ok, Worker1} = workforce:remote_checkout(Pid_or_name_of_pool).
    % defaults to: workforce:remote_checkout(Pid_or_name, 5000)
```

To always force the remote path even when in the same node use `workforce:remote_checkout(Pid_or_name, Timeout, force)`.

___
#### Async Checkouts

This form is for when you want full control of the request, e.g., you want to request workers from inside OTP behavioured processes without blocking. In this form you need to do mostly everything by yourself, in exchange it is completely asynchronous and you receive messages (use with care on distributed settings due to send and pray semantics - Amen!).

```erlang
    Mref = workforce:async_checkout(Pool_pid),
    receive {Mref, overloaded} -> ok end,
    demonitor(Mref, [flush]),
    Mref2 = workforce:async_checkout(Pool_pid),
    receive {Mref2, enqueued} -> ok end,
    receive {Mref2, Worker1} when is_pid(Worker1) ->
        workforce:async_confirm(Pool_pid, Mref2),
        % do work
        workforce:checkin(Pool_pid, Worker1),
        demonitor(Mref2, [flush])
    end.
```

A more complete example is further down.


___
#### Checkin

```erlang
    workforce:checkin(Pool_pid_or_name, Worker_pid).
```

___
#### Utility

```erlang
    #{
        state := State, % starting | ready
        queue := Queue, % queue:queue()
        pool := Pool, % queue:queue()
        q_count := Qc, % non_neg_integer() - Number of active requests enqueued
        p_count := Pc, % non_neg_integer() - Number of available workers
        q_track := Qtrack, % map() - Mapping of enqueued requests #{From => 0 | 1} (1 cancelled)
        active := Active, % non_neg_integer() - Number of Running workers
        starting := Starting, % non_neg_integer() - Number of Workers currently starting
        max_w := Max_w, % non_neg_integer() - Max number of allowed workers
        default_w := Def_w, % non_neg_integer() - Default number of workers
        max_q := Max_q, % integer() - -1 Unbound queue, 0 no queue, N > 0 Max N queue
        monitors := Monitors, % map() - Worker monitors refs
        checked_out := Cout, % map() - Currently checked out Worker mappings
        in_transit := It, % map() - Current workers currently checked out but not yet aknowledged as received,
        requests_monitors := Req_mons, % map() - Requester monitors refs mappings
        watcher := Watcher, % pid() - Pid of the watcher process gen_server
        ets := Ets, % reference() - ETS table reference for overload prechecks
        overloaded := O, % 0 | 1 - Current internal state, 0 not overloaded, 1 overloaded
        hibernate_when_free := HWF, % false | true - if should hibernate when totally free
        shrink_timeout := St % non_neg_integer | {nni, nni} - Intervals to decomission each additionally started worker
        
    } = workforce:state_as_map(Pool_pid_or_name).
    
```

___
#### Usage notes

Any of the API calls accepts the Pool name to be given as:
```
    Pid :: pid()
    Name :: atom() (when registered locally at start up)
    {local, Name :: atom()}
    {global, Term :: term()}
    {via, Module :: atom(), Term :: term()}
```
___
> workforce:checkout/1/2/3
```
    (Pid_or_name, Timeout :: timeout() - defaults to 5000, ForceEnqueue :: boolean() - defaults to false)
    
    % possible results
    {error, timeout}
    {error, overloaded}
    {error, {pool_down, Reason}}
    {error, {no_such_pool, Name}}
    {ok, Pid}
    
```
___
> workforce:remote_checkout/1/2/3

```
    (Pid_or_name, Timeout :: timeout(), force)
    
    % possible results 
    
    {error, overloaded}
    {error, {no_such_pool, Name}}
    {ok, Pid}
    
    call exception
```
___
> workforce:async_checkout/1/2

```

    (Pid_or_name, ForceEnqueue :: boolean())
    
    % possible results
    
    reference()
    {error, {no_such_pool, Name}}
```
Which can then be used to match incoming messages related to the request, the calling process may receive any of the following:

```
    {reference(), overloaded}
    {reference(), enqueued}
    {reference(), Pid} when is_pid(Pid)
    {'DOWN', reference(), _, Pool_pid, Reason}
```

On receiving a worker, the caller process needs to acknowledge it received the worker so the pooler can monitor the caller in order to return the worker in case of the caller crashing, with:
    `workforce:async_confirm(Pool_pid_or_name, Reference).`
    
In case you want to cancel a request you can use:
`workforce:async_cancel(Pool_pid_or_name, Reference).`
This will also demonitor the Reference.

If you don't call async_cancel you need to demonitor it yourself after receiving the Worker pid.
    
If you receive `{reference(), enqueued}` this means you will eventually either receive another `{reference(), Pid}` when your time reaches in the queue, or `{'DOWN'......}` if the pooler dies in the meanwhile.
    
___    
> workforce:checkin/2

```
    (Pid_or_name, Worker_pid)
    
    %possible results
    
    ok
```

___
#### Queues

The max_queue value should be used reasonably, usually a low number equal to the number of workers tends to improve the performance, while an unbound queue or a large queue might slow it down if the timeouts are short relative to its size and the average time a worker remains checked out. It all depends though and you should benchmark your particular scenarios to see if it improves or worsens. You can always force specific requests to be enqueued when checking out even if the queue is set to 0, the same if it's not set to 0 but full already, a forced checkout will always enqueue no matter what. This means you can have a queue for certain "regular" requests that is respected by these requests and then always force some specific requests to be enqueued.

___
#### Workers

The workforce_watcher is responsible for starting workers. Right now it's not a supervisor so a worker that repeatedly crashes will go unnoticed, meaning it won't trigger a supervisor failure. This might change in the future if requested.

It calls apply(M, F, A) and doesn't link by default to the worker, only monitors it. On an controlled shutdown it will tell all workers to exit with `shutdown`, and the same when an extra worker is to be removed. You probably want to use a linking start for your workers so they go down in the event the watcher goes down.

___
#### Asynchronous Example in a gen_server

```erlang
-module(async_example).
-behaviour(gen_server).

-export([start_link/1, init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {
    refs = #{} :: map(),
    workers = #{} :: map(),
    monitors = #{} :: map(),
    config = #{} :: map(),
    }
).

start_link(Config)->
    gen_server:start_link(?MODULE, Config, []).

init(Config)->
    {ok, #state{config = Config}}.
    
handle_call({start_work, Data}, {Pid, _}, #state{refs = Refs} = State)->
    Mref = workforce:async_checkout(workforce, true),
    N_refs = maps:put(Mref, {Pid, waiting, Data}, Refs),
    erlang:send_after(15000, self(), {Mref, timeout}),
    {reply, {ok, Mref}, State#state{refs = N_refs}};
    
handle_call({Mref, finished, Results}, {Pid, _}, #state{monitors = Mons, workers = Workers} = State) ->
    {{P_ref, Mref, Worker_pid, _}, N_mons} = maps:take(Pid, Mons),
    {{Mref, Original_caller, _}, N_workers} = maps:take(Worker_pid, Workers),
    ets:insert(some_public_ets, Results),
    workforce:checkin(workforce, Worker_pid),
    demonitor(P_ref, [flush]),
    Original_caller ! {finished, Mref},
    {reply, ok, State#state{monitors = N_mons, workers = N_workers}}.
    
handle_info({Mref, enqueued}, #state{refs = Refs} = State) when is_map_key(Mref, Refs) ->
    N_refs = maps:update_with(Mref, fun({Pid, _, Data})-> {Pid, enqueued, Data} end, Refs),
    {noreply, State#state{refs = N_refs}};
    
handle_info({Mref, Pid}, #state{refs = Refs, workers = Workers} = State) when is_pid(Pid), is_map_key(Mref, Refs) ->
    {{Original_caller, _, Data}, N_refs} = maps:take(Mref, Refs),
    N_workers = maps:put(Pid, {Mref, Original_caller, Data}, Workers),
    workforce:async_confirm(workforce, Mref),
    demonitor(Mref, [flush])
    Original_caller ! {starting_work, Mref},
    {noreply, State#state{refs = N_refs, workers = N_workers}, {continue, {work, Pid}}};
    
handle_info({Mref, overloaded}, #state{refs = Refs} = State) when is_map_key(Mref, Refs) ->
    {{Original_caller, _, _}, N_refs} = maps:take(Mref, Refs),
    Original_caller ! {failed, Mref},
    {noreply, State#state{refs = N_refs}};
    
handle_info({Mref, timeout}, #state{refs = Refs} = State) when is_map_key(Mref, Refs) ->
    {{Original_caller, _, _}, N_refs} = maps:take(Mref, Refs),
    workforce:async_cancel(workforce, Mref),
    Original_caller ! {failed, Mref},
    {noreply, State#state{refs = N_refs}};
    
handle_info(_, State)-> {noreply, State}.
    
handle_continue({work, Pid}, #state{workers = Workers, monitors = Mons} = State) ->
    {Mref, _, Data} = maps:get(Pid, Workers),
    {P_pid, P_ref} = spawn_monitor(some_module, do_work, [Mref, self(), Pid, Data]),
    N_mons = maps:put(P_pid, {P_ref, Mref, Pid, Data}, Mons),
    {noreply, State#state{monitors = N_mons}}.
    
handle_cast(_, State) -> {noreply, State}.
```

This is a fairly contrived example, because there's no reason to be async, but there could be, it's just to illustrate how it can be used, there's missing handles for dealing with processes going down, etc...

___
#### Benchmarks

There's some comparisons with poolboy in the `benchmarking` folder, [Read](/benchmarking/README.md), and also the module used to run them. If you want to run them yourself you'll need to create a folder, copy all modules from /src into it, add the poolboy modules and then you can try it out from an erl shell. I'll try to checkout other pooler implementations to compare and add there.

___
#### TODO

- Maybe switch the watcher implementation to be a supervisor instead of a gen_server;
- Add common tests to test the various checkouts when requester node is different from the workforce node


![Cocktail Logo](https://github.com/mnussbaumer/workforce/blob/master/logo/cocktail_logo.png?raw=true "Cocktail Logo")

[© rooster image in the cocktail logo](https://commons.wikimedia.org/wiki/User:LadyofHats)

```
Copyright [2019] [Micael Nussbaumer]

Licensed under the Apache License, Version 2.0 (the "License");
you may not use the files contained in this library except in 
compliance with the License.

You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```
