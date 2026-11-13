# ADR-0011: Engine kernels in C and a worker pool on the frame path

Status: Accepted. "What is split" is replaced by ADR-0012.

## Context

The engine rebuilt for the published model (ADR-0010) was correct and too slow: no tier met
the tier rule's budget (ADR-0004). A profile of one frame put almost all of the time in the
Mamba recurrences. Per bin and per scan the recurrence evaluates 4,096 exponentials and as
many multiply-adds on its 256 x 16 state, and the Swift code spent that time in `vvexpf` and
in about fifty Accelerate calls on 256-value vectors. Nothing was allocated or reference
counted per frame, so there was no waste of that kind to remove; the cost was arithmetic
and call overhead, on one thread.

## Decision

**Kernels.** The recurrence step, SiLU, the exponential inside softplus, layer normalisation
and PReLU are C functions in a small package target, `UntunnelKernels`, written with the
compiler's portable vector types. The exponential is computed in line as a power of two
(a degree-six polynomial, accurate to single precision; the test states the bound). The
state is stored as `[channel][lane]`, so the sixteen lanes of a channel are one vector and
a step is one pass over memory. Swift's own `SIMD16` was tried first and rejected: the same
loop ran several times slower than the Accelerate version it replaced.

**Matrix product.** The products were Accelerate's until hops were tested for allocation by
counting calls to the allocator instead of watching the heap grow: `cblas_sgemm`, which
`vDSP_mmul` calls, takes a buffer from the allocator and returns it on every call above a
small size. The count is the test's; the heap never grew, so the earlier test passed.
`untunnel_matmul` replaces it on the frame path. On a processor with the Arm matrix
extension it accumulates outer products on the matrix unit, turning each block of the
row-major input into columns in registers so nothing is packed or copied; elsewhere it is a
loop over vector registers. Both sum each output over the depth in order with fused multiply-adds, so
they agree to the last bit and a test holds each to that sum. The matrix unit is one per
cluster of cores, not one per core: products from several threads take turns on it.

**Worker pool.** `WorkerPool` owns one thread per performance core beyond the caller's,
created with the first restorer. A stage of a frame is published as a function pointer, a
context and a chunk count through one atomic word; the submitting thread and the workers
claim chunks with a compare-and-swap, and a sleeping worker is woken with a Mach semaphore.
The frame path takes no lock, allocates nothing and uses no dispatch queue. The submitter
claims chunks itself, so a worker that is late costs time, never correctness, and a second
restorer that submits while the pool is busy runs its stage on its own thread.

**Scheduling class.** The workers request the time-constraint class, with the hop as their
period. At user-interactive priority they lost their cores to ordinary busy threads and the
submitter waited for them. They look for work only briefly before sleeping, because a
worker that keeps spinning in that class holds a core the submitter needs.

The thread that calls a restorer has to be in the same class (`RealtimeThread`), and the
pipeline thread and the benchmark thread now ask for it. The argument that neither side can
hold the other up:

- A submitter never waits for a lock or for a sleeping thread. It waits only for chunks that
  a worker has claimed and is running, and it runs every unclaimed chunk itself.
- A worker that holds a chunk is in the submitter's class, so nothing an application runs at
  an ordinary priority takes its core. If the submitter were in a lower class instead, it
  would be the one preempted, with its chunks claimed and the workers idle.
- Another time-constraint thread can take a worker's core: the second path's submitter, or
  the system's audio threads. Threads of this class are not preempted for one another until
  a quantum of several milliseconds runs out, so a submitter that only spun while it waited
  could keep the worker it is waiting for off a core for that long. It yields its core every
  few hundred looks instead (`thread_switch`), which returns at once when no thread of its
  class is waiting to run.
- A worker with nothing to do gives up after a fixed number of looks and sleeps on a
  semaphore, so an idle worker cannot keep a core from the submitter for longer than that.

**What is split.**

- Time branch: bins are independent sequences, so ranges of bins are chunks.
- Frequency sweeps: projection, preparation and readout are chunks of bins for both
  directions at once. The recurrence is sequential in the bins, but affine in the state:
  the second half of each direction is walked from a zero state at the same time as the
  first, keeping the running product of its decay factors, and the first half's final state
  is then added to the second half's readouts through those products.
- Dense blocks: within a layer, ranges of bins are chunks.

**Parity.** The tolerances of ADR-0010 are unchanged and both parity suites pass. The
phased sweep and the kernels each have a test against the one-pass or library form.

**Checks.** `make test-tsan` runs the engine's tests under ThreadSanitizer. It found one race:
a worker could read the job's function and context while the next job was being published.
The read was discarded when its claim failed, and it is now two atomic words.
`make test-optimized` runs, with optimisation on, the tests whose result depends on it: a
hop makes no call to the allocator on the calling thread or on a worker, at a test size and
at a tier's size; and with every core kept busy at user-interactive priority and two
time-constraint submitters sharing the pool, no job takes longer than the computation a
worker declares per period. Both targets are part of `make check`.

## Alternatives measured

- More workers than performance cores: no gain.
- Single-threaded BLAS: no change; Accelerate does not thread products of this size.
- A longer idle spin in the workers: slower, for the reason above.
- The recurrences on the GPU, in a prototype kept outside the repository: one Metal kernel
  per time step, and one GPU thread per channel and direction for the sweeps, ran the
  recurrence load of the largest tier in a fraction of a frame, including the per-frame
  wait for the command buffer. Moving the block stack there is the route for the tiers the
  CPU cannot hold; it is not part of this decision and no number from the prototype is a
  claim about the engine.

## Consequences

- The package has a C target. Only the matrix product is specific to a processor, and it
  is compiled for arm64 alone with the portable loop beside it, so the target builds for
  every architecture the Swift targets build for.
- The matrix product declares the few `<arm_sme.h>` intrinsics it uses itself, because the
  header cannot be included from a package built with modules. A compiler that renames
  them fails the build; it cannot change a result.
- The engine starts threads. They exist for the life of the process and sleep when no
  restorer is running.
- A tier's cost now depends on the machine's free performance cores as well as its speed;
  `untunnel bench` measures that, and its report names the tiers inside the budget.
- Each sweep keeps one product row per bin of its second half, 16 KiB each.
