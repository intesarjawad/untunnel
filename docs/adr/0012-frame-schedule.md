# ADR-0012: How a frame is scheduled across one matrix unit and the cores

Status: Accepted. Replaces "What is split" in ADR-0011.

## Context

After ADR-0011 the engine held one tier inside the tier rule's budget (ADR-0004) and the
next one sat on the line. Two things about the machine, both measured, decided what to do
next.

**The matrix unit is shared.** A processor with the Arm matrix extension has one matrix unit
per cluster of cores. A matrix product on it is several times faster than the same product
on vector registers, and running products on several threads at once gives little more
than running them on one. ADR-0011 split every dense layer and every projection into chunks
for the worker pool, so four threads queued for one unit.

**A live stream is not a loop.** `untunnel bench` used to call the restorer back to back from
a thread of ordinary priority. A stream delivers a hop every 20 ms to a time-constraint
thread, and between hops the workers sleep. Measured that way the frame was slower than the
loop had said, and most of the difference was workers being woken: a frame is five jobs
per block with a product between them, and the workers went to sleep during every product
and were woken by a system call for the next job.

## Decision

**Products on the calling thread, the rest on the pool.** Each matrix product runs whole on
the thread that calls the restorer. Everything between two products is shared with the
workers: the recurrence's convolution and activations, its preparation, and the recurrence
itself. `SelectiveScan` offers these as stages and `RealtimeBlock` runs them in order.

**Dense layers read their taps in place.** A layer of a dense block summed nine taps gathered
into one patch per bin. `untunnel_matmul` takes a row stride, and each tap is a window of
the rows of one stored frame, so a layer is nine products that add into the same output and
the gathering is gone. The sum runs over the taps in the same order as before.

**A sweep is shared by channels.** The frequency recurrence walks the bins in order, and
ADR-0011 split the walk in two halves and repaired the second with the product of its
decay factors. The channels of a recurrence do not depend on each other, so a sweep is now
shared as ranges of channels, each walking every bin. The arithmetic is the one-pass
sweep's exactly, which a test checks for equality, and the second kernel, the products and
the repair stage are deleted.

**Workers stay awake for the length of a frame.** `WorkerPool.beginFrame` wakes the workers
and `endFrame` lets them sleep; in between a worker without a job keeps looking for one.
A worker that is only looking yields its core every few hundred looks, like the submitter
that waits for its last chunks (ADR-0011). Without the yield, more waiting threads than
cores stalled jobs for a scheduling quantum each: a pool given more workers than cores, and
once two streams on the normal pool, ran frames many times too long. A test runs a frame on
twice as many workers as cores and bounds every job.

**One workspace per stream.** The arrays a recurrence computes a frame in are shared by the
blocks of a stream, which run one after another, instead of each scan owning a set.

**The benchmark runs as a stream does.** Each pass asks for the time-constraint class and
starts one frame per hop, sleeping in between. Streams measured together start their hops
together, the case in which they share the pool the least. Numbers taken before this change
are not comparable with numbers taken after it.

## Measured

`docs/bench.md` holds the passes of this engine on the reference machine and names the tiers
inside the budget; it is the only source for a number. Every tier in the default set is now
inside it there, on the processor alone.

## Alternatives rejected

- **The block stack on the GPU.** This was the route ADR-0011 named for the tiers the
  processor could not hold. It is not taken, for three reasons. No tier in the default set
  is left outside the budget. A frame is a chain: the encoder feeds the blocks and the
  blocks feed the decoders, so a GPU would not run beside the processor but instead of it,
  and it would have to finish all blocks, wait for its command buffer included, in less
  time than the processor now takes for them. And Metal allocates for every command buffer,
  so the submission would need a thread of its own and a bounded wait with a fallback tier,
  which is machinery to justify with a measured gain, not ahead of one. Nothing was
  measured on a GPU inside the engine. If a later model or
  a slower machine leaves a tier outside the budget, the measurement to make first is the
  whole block stack on the GPU against the "blocks" share of a frame here.
- **More workers than performance cores.** With the workers awake and yielding it is no
  longer harmful and still not faster.
- **Workers that sleep between jobs with a longer look first.** Faster than sleeping at once
  and slower than staying awake for the frame, and it kept cores busy after the frame.
  ADR-0011 measured a longer look as slower; the calling thread was then in a lower class
  than the workers, and they took its core.
- **Accelerate's product.** It allocates on every call (ADR-0011).

## Consequences

- A frame's speed depends on the matrix unit, which other processes can use as well.
  `untunnel bench` on the user's machine measures what is left of it.
- The workers stay awake for as long as a frame takes. That is processor time spent on
  latency; it ends with the frame.
- On a processor without the matrix extension the products are vector loops on the calling
  thread alone. The tier rule measures that machine and picks what it can hold.
