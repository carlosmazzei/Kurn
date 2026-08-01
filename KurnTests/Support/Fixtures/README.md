# Prerecorded audio fixtures

AAC `.m4a` inputs for the tests whose subject is reading or re-encoding a
recording (`RecordingCompactorTests`). They are committed rather than encoded at
run time because writing AAC on a loaded CI simulator intermittently produces a
container the reader rejects — indistinguishable, from the test's point of view,
from the compaction failure it is looking for.

Regenerate with:

```bash
ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=3.0" \
  -ac 1 -c:a aac -b:a 64k tone-44100-64kbps-3s.m4a

ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=16000:duration=2.0" \
  -ac 1 -c:a aac tone-16000-2s.m4a
```

- `tone-44100-64kbps-3s.m4a` — the shape the recorder produced before the fixed
  24 kHz storage format, i.e. worth compacting.
- `tone-16000-2s.m4a` — already below the storage rate, so compaction must not
  resample it up. The codec picks the bit rate: 64 kbps is rejected outright at
  16 kHz.
