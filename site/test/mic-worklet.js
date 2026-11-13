// The worklet only moves blocks to the page; the page owns the preallocated take buffer.
class TakeRecorder extends AudioWorkletProcessor {
    process(inputs) {
        const input = inputs[0];
        const channel = input && input[0];
        if (channel && channel.length > 0) {
            const copy = channel.slice();
            this.port.postMessage(copy, [copy.buffer]);
        }
        return true;
    }
}

registerProcessor("take-recorder", TakeRecorder);
