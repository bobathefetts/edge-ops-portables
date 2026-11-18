/* Local Whisper ONNX WASM worker (adapted from PacketRat voice-worker.js). No network access. */
let asr = null;

async function load() {
  const lib = await import('/vendor/voice/transformers.min.js');
  const env = lib.env;
  env.allowRemoteModels = false;
  env.allowLocalModels = true;
  env.localModelPath = '/vendor/voice/models/';
  env.useBrowserCache = false;
  env.backends.onnx.wasm.wasmPaths = '/vendor/voice/';
  env.backends.onnx.wasm.numThreads = 1;
  asr = await lib.pipeline('automatic-speech-recognition', 'whisper-tiny.en', { dtype: 'q8', device: 'wasm' });
}

self.onmessage = async (e) => {
  const m = e.data || {};
  try {
    if (m.type === 'load') {
      await load();
      self.postMessage({ type: 'ready' });
    } else if (m.type === 'transcribe') {
      if (!asr) throw new Error('The Whisper WASM model is not loaded.');
      const out = await asr(m.audio);
      self.postMessage({ type: 'text', id: m.id, text: String((out && out.text) || '').trim() });
    }
  } catch (err) {
    self.postMessage({ type: 'error', id: m.id, message: String((err && err.message) || err) });
  }
};
