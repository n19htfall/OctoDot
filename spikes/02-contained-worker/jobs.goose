// OctoDot M0, spike 02: background jobs in contained workers, started from
// exported calls and reported back through typed queues and a host wake-up.
//
// The pattern the real engine will use for scheme compiles, imports and
// compaction:
//   1. An export starts a small supervisor worker for each job and returns
//      the job id at once.
//   2. The supervisor starts the real work as a *contained* worker and
//      blocks in thread_wait for it. That is how it learns of an abort, which
//      the work itself can never report.
//   3. The supervisor queues a JobDone and calls octo_host_wake(), which
//      the host implements to poke its main run loop.
//   4. On its main thread, the host calls octo_pump(), which drains the
//      queues into a job table the host can query.
// Worker code touches no globals: a worker gets copies taken at spawn, and
// a non-flat global is an error in anything a worker can reach.
import std;

extern fn octo_host_wake();     // in the host; called from worker threads

let KIND_SUM = 1;       // add up 1..n
let KIND_OOB = 2;       // index n of a 3-element array: a contained abort
let KIND_ASSERT = 3;    // a failed assert, also contained

let PENDING = 0;
let SUCCEEDED = 1;
let FAILED = 2;

// Everything that crosses between programs is flat: no references.
struct JobArgs { id: i64, kind: i64, n: i64 }
struct WorkResult { id: i64, value: i64 }
struct JobDone { id: i64, ok: bool, why: u8[..200] }

thread_fn work(job: JobArgs) {
    var value: i64 = 0;
    if job.kind == KIND_SUM {
        for i in job.n { value += i + 1; }
    } else if job.kind == KIND_OOB {
        let small: i64[3] = [10, 20, 30];
        value = small[job.n];
    } else if job.kind == KIND_ASSERT {
        assert(job.n < 0);
    }
    qput(WorkResult { id: job.id, value: value });
}

thread_fn supervise(job: JobArgs) {
    var why: u8[>..] = [];
    let ok = thread_wait(thread_spawn_contained(work, job), why);
    let keep = if why.len > 200 { 200 } else { why.len };
    qput(JobDone { id: job.id, ok: ok, why: why[..keep] });
    octo_host_wake();
}

// The main program's job table: ids are 1, 2, 3 ... so a job is at id - 1.
struct JobRecord { state: i32, value: i64, why: u8[..200] }

var jobs: JobRecord[>..];
var supervisors: i64[>..];      // thread ids, so octo_quiesce can wait for them
var why_out: u8[>..];

fn job_index(id: i64) -> i64 {
    if id >= 1 && id <= jobs.len { id - 1 } else { -1 }
}

export fn octo_request(kind: i64, n: i64) -> i64 {
    jobs.push(JobRecord { state: PENDING, value: 0, why: "" });
    let id = jobs.len;
    supervisors.push(thread_spawn(supervise, JobArgs { id: id, kind: kind, n: n }));
    return id;
}

// Applies whatever finished since the last call; returns how many jobs did.
export fn octo_pump() -> i64 {
    loop {
        let r, has = qpoll<WorkResult>();
        if !has { break; }
        let i = job_index(r.id);
        if i >= 0 { jobs[i].value = r.value; }
    }
    var finished: i64 = 0;
    loop {
        let d, has = qpoll<JobDone>();
        if !has { break; }
        let i = job_index(d.id);
        if i >= 0 {
            jobs[i].state = if d.ok { SUCCEEDED } else { FAILED };
            jobs[i].why = d.why;
            finished += 1;
        }
    }
    return finished;
}

export fn octo_job_state(id: i64) -> i32 {
    let i = job_index(id);
    if i >= 0 { jobs[i].state } else { -1 }
}

export fn octo_job_value(id: i64) -> i64 {
    let i = job_index(id);
    if i >= 0 { jobs[i].value } else { 0 }
}

// A failed job's abort message: the check and its source location only.
export fn octo_job_why(id: i64) -> const u8[:] {
    why_out.clear();
    let i = job_index(id);
    if i >= 0 { why_out.append(jobs[i].why); }
    return why_out;
}

// Blocks until every supervisor has exited. goose_exit is a runtime error
// while any worker still runs, and a supervisor outlives its JobDone by a
// moment, so a host calls this before goose_exit.
export fn octo_quiesce() {
    for id in supervisors { thread_wait(id); }
    supervisors.clear();
}
