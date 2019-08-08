
It's difficult to create throughly faithful and relevant benchmarks for a pooler. The reason is that for an actual pooling situation resembling anything in the real world it involves several processes requesting access to workers. This means that there's always an overhead of processes involved. Also, linear time spent checking in and out is not a very good measurement, since in most cases what will happen is that several processes, with a finite timeout want to get a worker on their hands to then do something, after which they check in. So to benchmark this it's necessary to spawn a lot of processes, make them all request workers, make them tell some other process if they were able or not to get a checkout, and if they were, they need to hold the checked out worker for a little while and then check it back in after that timespan. There's a module (tests.erl) that was used to arrive at these values, and it's only benchmarked against Poolboy, for nothing special, but because it's one of the most common poolers in Elixir/Erlang and is used by some important mainstream libs. Having said that, in most usual scenarios it's not the speed of the pooler that will be the most important thing, but in high volume traffic it can have some noticeable impact.

To use it, copy all workforce modules from /src & the test_worker.erl from /test and do the same for poolboy's repo's /src. Compile all the modules including `benchmarking.erl` and then do (remember to run erl with at least +P 1000000 or you'll run out of processes, and do some runs to warm up, restart the shell and do them in different orders, etc):
```erlang
    benchmarking:start().
    benchmarking:trasher(workforce, 1500, 16). %or poolboy instead of workforce
```

You can configure some settings on the module itself (amount of workers - notice that poolboy max_overflow means + X workers than the baseline, while on workforce max_workers - default_workers is what gives the amount of overflow, so poolboy 25, 25 is equivalent to workforce 25, 50).

Running that command with the defaults, meaning, no enqueuing of requests, they either succeed of fail, each successful checkout holds the worker for 50milliseconds then checks it back in. 25 Default workers, with 25 extra allowed and a 10sec timeout for the requests.
1500 milliseconds wait between each run, doing 16 runs.
Each run does 1000 cycles, spawning 200 processes for check out (means 200_000 checkout attempts each second and a half, some will overlap).
On a successful checkout the process sends a message saying ok, else failed. A listening process is started for each run, and a master one for the full group of runs, which receives the results of each run and aggregates them. The results fluctuate but are pretty much normalised after so many runs and they don't deviate significantly, anyway give it a try.

```
poolboy
 OK: 1967 ||| Failed: 3198033
 AvgOK: 123 ||| AvgFailed: 199877 
 Total Time: 26.824999999999996 ||| Avg/Run: 1.6765624999999997

workforce
 OK: 2596 ||| Failed: 3197404
 AvgOK: 162 ||| AvgFailed: 199838 
 Total Time: 9.891000000000002 ||| Avg/Run: 0.6181875000000001
```

There's also the fact that there's no counterpart to the finite queue in workforce. Using in the same scenario a finite queue of 100, usually yields better results when using such a generous timeout.

```
workforce
 OK: 3599 ||| Failed: 3196401
 AvgOK: 225 ||| AvgFailed: 199775 
 Total Time: 10.035999999999998 ||| Avg/Run: 0.6272499999999999
```

With a more limited timeout of 3seconds (and the queue again set to 0 on workforce).

```
poolboy
 OK: 2097 ||| Failed: 3197903
 AvgOK: 131 ||| AvgFailed: 199869 
 Total Time: 25.928999999999995 ||| Avg/Run: 1.6205624999999997
 
 
workforce
 OK: 3638 ||| Failed: 3196362
 AvgOK: 227 ||| AvgFailed: 199773 
 Total Time: 11.755 ||| Avg/Run: 0.7346875
```

Diminishing to 10 fixed workers and 500 cycles, 200 processes per cycle, meaning 100_000 spawned processes/round.

```
poolboy
 OK: 526 ||| Failed: 1599474
 AvgOK: 33 ||| AvgFailed: 99967 
 Total Time: 13.715 ||| Avg/Run: 0.8571875

workforce
 OK: 608 ||| Failed: 1599392
 AvgOK: 38 ||| AvgFailed: 99962 
 Total Time: 7.319000000000001 ||| Avg/Run: 0.45743750000000005
```

Still almost half the time, but with a max queue of 20 in workforce:

```
workforce
 OK: 850 ||| Failed: 1599150
 AvgOK: 53 ||| AvgFailed: 99947 
 Total Time: 7.485 ||| Avg/Run: 0.4678125
```
If we crank the cycles to 1000 again:

```
poolboy
 OK: 524 ||| Failed: 3199476
 AvgOK: 33 ||| AvgFailed: 199967 
 Total Time: 25.189 ||| Avg/Run: 1.5743125
 
workforce
 OK: 485 ||| Failed: 3199515
 AvgOK: 30 ||| AvgFailed: 199970 
 Total Time: 11.256 ||| Avg/Run: 0.7035
```

To test Unbound queues (by forcing all requests to be enqueued) with timeouts (increased to 5secs) reducing the cycles to 500 again, and increasing the wait between runs to 2.5secs (otherwise both just become overloaded for a long time). Now an interesting note - on all other runs I wasn't using try...of...catch around the poolboy:checkout but when using unbound queues it's obligatory because otherwise we don't receive any failures (and probably in real life you'll be doing it anyway in case of failure? - in this case, poolboy just gets overload after 1 or 2 runs and never gets back to its feet. I would like to know if I'm wrong here...):

```
catching exceptions in poolboy
First run
poolboy
 OK: 486 ||| Failed: 1599514
 AvgOK: 30 ||| AvgFailed: 99970 
 Total Time: 88.94699999999999 ||| Avg/Run: 5.559187499999999
ok

All other runs it just takes way too long/is overrun.

without catching exceptions: 
poolboy
 OK: 493 ||| Failed: 0
 AvgOK: 31 ||| AvgFailed: 0 
 Total Time: 5.007000000000001 ||| Avg/Run: 0.31293750000000004

(see how there was no failed reports in all those because of the way it's setup to receive messages in order to define how much time it took to run, all runs except the one with 493 checkouts report times of 0.001 seconds.) And also after 1 run it no longer works at all and the VM goes crazy.
 

workforce
 OK: 2545 ||| Failed: 1597455
 AvgOK: 159 ||| AvgFailed: 99841 
 Total Time: 88.47 ||| Avg/Run: 5.529375
```

When running in pure unbound queues with no timeouts at all (which is not a very normal scenario but might happen), we set timeout to infinity, decrease to 8 runs, 100 cycles each with 50 requests (5_000 reqs  * 8), 40 fixed workers, a checkout hold of 10ms and 2,5 sec between each round:

```
poolboy
 OK: 40000 ||| Failed: 0
 AvgOK: 5000 ||| AvgFailed: 0 
 Total Time: 11.796 ||| Avg/Run: 1.4745
 
 workforce
 OK: 40000 ||| Failed: 0
 AvgOK: 5000 ||| AvgFailed: 0 
 Total Time: 11.016 ||| Avg/Run: 1.377

```
Here the results are mostly the same, but the interesting part is if you increase the cycles for instance to 200 cyles 100 requests, then poolboy starts lagging behind heavily (in fact I had to decrease it so to be able to compare anything). 

Lastly, to check pure checkout speeds. No waiting time between checkout and checkin and no waiting time between processes.

```
poolboy
 OK: 40000 ||| Failed: 0
 AvgOK: 5000 ||| AvgFailed: 0 
 Total Time: 7.037 ||| Avg/Run: 0.879625
 
workforce
 OK: 40000 ||| Failed: 0
 AvgOK: 5000 ||| AvgFailed: 0 
 Total Time: 0.919 ||| Avg/Run: 0.114875

% cranking up 4x the number of requests

workforce
 OK: 160000 ||| Failed: 0
 AvgOK: 20000 ||| AvgFailed: 0 
 Total Time: 3.7439999999999998 ||| Avg/Run: 0.46799999999999997
```

I think overall it performs better, and specially under heavy load - most of the tests before were without setting a proper try...catch around the poolboy call which when set increases the cost as well and worsens further its avgs.
