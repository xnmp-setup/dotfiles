"""Local Silero ONNX inference on 32 ms microphone frames."""
from pathlib import Path

MODEL_SHA256 = "1a153a22f4509e292a94e67d6f9b85e8deb25b4988682b7e174c65279d8788e3"

class SpeechDetector:
    def __init__(self) -> None:
        import hashlib
        import numpy as np
        import onnxruntime as ort
        model = Path(__file__).parent / 'models/silero_vad.onnx'
        if hashlib.sha256(model.read_bytes()).hexdigest() != MODEL_SHA256:
            raise ValueError('Speech model checksum mismatch')
        options = ort.SessionOptions()
        options.inter_op_num_threads = 1
        options.intra_op_num_threads = 1
        self.session = ort.InferenceSession(str(model), options, providers=['CPUExecutionProvider'])
        self.state = np.zeros((2, 1, 128), dtype=np.float32)
        self.context = np.zeros((1, 64), dtype=np.float32)

    def probability(self, pcm: bytes) -> float:
        import numpy as np
        if len(pcm) != 1024:
            raise ValueError('Expected 512 mono s16 samples at 16 kHz')
        samples = np.frombuffer(pcm, dtype='<i2').astype(np.float32).reshape(1, 512) / 32768.0
        audio = np.concatenate((self.context, samples), axis=1)
        probability, self.state = self.session.run(None, {
            'input': audio, 'state': self.state, 'sr': np.array(16000, dtype=np.int64),
        })
        self.context = audio[:, -64:].copy()
        return float(probability[0, 0])
