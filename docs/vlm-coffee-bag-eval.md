# Coffee Bag VLM Evaluation

This is the first validation step before wiring VLM extraction into the iOS app.
The goal is to test whether a vision model can reliably produce an editable bean
draft from one or two coffee bag photos.

## Recommendation

Use direct Ark/Doubao vision API for this realtime app flow first. AI Data Lake is
better for offline batches, large imports, badcase mining, or dataset evaluation,
but it is not the first integration point for an interactive iOS scan.

For the current private prototype, keep this shape:

```text
iOS app -> Ark Responses API -> JSON validation -> editable Add Bean draft
```

The API key is compiled/configured locally for now. Keep `config.json` out of
git. If the app is distributed beyond trusted personal devices, move the key
behind a serverless proxy.

## Local Smoke Test

The probe can read `config.json`:

```json
{
  "api_key": {
    "secret": "ark-..."
  },
  "model": "doubao-seed-1-6-flash-250828",
  "base_url": "https://ark.cn-beijing.volces.com/api/v3"
}
```

The only required field is `api_key.secret`. The script defaults to the external
Ark base URL and `doubao-seed-1-6-flash-250828`.

Environment variables still override config:

```bash
export ARK_API_KEY="..."
export ARK_MODEL="doubao-seed-1-6-flash-250828"
export ARK_BASE_URL="https://ark.cn-beijing.volces.com/api/v3"
```

Run on one or two local photos:

```bash
python3 scripts/coffee_bag_vlm_probe.py /path/to/front.jpg /path/to/back.jpg
```

Or run against a remote image URL:

```bash
python3 scripts/coffee_bag_vlm_probe.py --image-url https://example.com/bag.jpg
```

The script uses the Ark Responses API and asks for strict JSON with evidence and
confidence.

For the faster App-style path, use low image detail and the compact schema:

```bash
python3 scripts/coffee_bag_vlm_probe.py /path/to/front.jpg \
  --model ep-20260516191128-js45j \
  --detail low \
  --prompt-mode compact \
  --max-tokens 1500
```

## Expected JSON Check

For a known sample, create a small expected JSON subset:

```json
{
  "coffee": {
    "roaster": "Savage",
    "name": "Radiance",
    "origin": "Chiriqui, Panama",
    "farm": "Finca Deborah",
    "variety": "Geisha",
    "process": null,
    "flavor_notes": ["Nectarine", "Pomegranate", "Black Tea"]
  },
  "bag": {
    "roast_date": null,
    "total_grams": null
  }
}
```

Then run:

```bash
python3 scripts/coffee_bag_vlm_probe.py front.jpg back.jpg --expected expected.json
```

## Batch Model Evaluation

Run the Add Bean model-selection benchmark:

```bash
python3 scripts/evaluate_coffee_bag_models.py --force-run
```

This will:

- convert `test_images/*` into `.generated/vlm_eval/prepared/*.jpg`;
- send each compressed image as a base64 data URL through Ark Responses API;
- compare `doubao-seed-1-6-flash-250828`, `doubao-seed-1-6-251015`, and
  `doubao-seed-1-8-251228`;
- score accuracy against `eval/coffee_bag_expected_labels.json`;
- write `.generated/vlm_eval/summary.md` and raw per-case JSON results.

Focused App-speed variants can be run like this:

```bash
python3 scripts/evaluate_coffee_bag_models.py \
  --models ep-20260516191128-js45j \
  --detail low \
  --prompt-mode compact \
  --max-side 1800 \
  --jpeg-quality 80 \
  --max-tokens 1500 \
  --output-dir .generated/vlm_eval_low_compact_1800 \
  --force-prepare \
  --force-run
```

Cost estimation is optional. Token usage is always reported. To estimate cost,
add a local-only pricing table to `config.json`:

```json
{
  "pricing": {
    "doubao-seed-1-6-flash-250828": {
      "input_per_million": 0,
      "output_per_million": 0,
      "currency": "CNY"
    }
  }
}
```

## Pass Criteria

A model is good enough to integrate when it satisfies these checks on a small
sample set of real bags:

- It returns valid JSON in at least 95% of requests.
- It uses `null` instead of hallucinating missing roast date, process, or weight.
- It gets roaster, coffee name, origin, farm, variety, and visible flavor notes
  correct on most clean photos.
- It returns evidence strings that make wrong fields easy to debug.
- Latency is acceptable for an Add Bean flow. Current Seed 1.8 endpoint tests
  are closer to 15-20 seconds with the compact prompt, so the UI should show an
  explicit scanning/progress state instead of feeling instantaneous.

## 2026-05-16 App-Speed Test

All rows below use the production Ark endpoint `ep-20260516191128-js45j` and
Responses API base64 image input. Each run has 5 coffee-bag cases.

| variant | weighted accuracy | JSON valid | avg latency ms | p95 latency ms | input tokens | output tokens | total tokens | avg image bytes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| `low/full/1800/max5000` | 0.9343 | 1.0000 | 32488.6 | 51293 | 8935 | 6596 | 15531 | 422070.8 |
| `low/full/1400/max5000` | 0.9037 | 1.0000 | 29285.0 | 49007 | 7070 | 6184 | 13254 | 260056.0 |
| `low/full/1200/max5000` | 0.9148 | 1.0000 | 32935.0 | 43638 | 6088 | 7656 | 13744 | 200128.4 |
| `low/compact/1800/max1500` | 0.9343 | 1.0000 | 15587.2 | 19879 | 7660 | 3177 | 10837 | 422070.8 |
| `low/compact/1400/max1500` | 0.9222 | 1.0000 | 19523.8 | 32656 | 5795 | 3803 | 9598 | 260056.0 |

Conclusion for the current App default:

- Set `input_image.detail` to `low`.
- Use the compact prompt without `evidence` and `confidence`.
- Lower `max_output_tokens` from 5000 to 1500.
- Keep image compression at longest side `1800px`, JPEG quality `0.8` for now.

The 1400px and 1200px variants reduce input size and tokens, but they introduce
more field misses and did not reliably improve latency on this small sample.

## Next Integration Step

The iOS Add Bean scan flow uses the same Responses API path:

- Compress selected camera/library images to JPEG.
- Send them as base64 data URLs in `input_image.image_url`.
- Call Ark Responses API with the Seed 1.8 endpoint.
- Validate and coerce JSON into the Coffee Journal draft schema.
- Return a clear failure state if model extraction fails.

For personal true-device testing, install the debug app and seed Keychain from
ignored local `config.json`:

```bash
python3 scripts/seed_ark_keychain.py
```

If CoreDevice launch is flaky, run once from Xcode with these Run environment
variables:

```text
ARK_API_KEY=<your key>
ARK_MODEL=ep-20260516191128-js45j
ARK_BASE_URL=https://ark.cn-beijing.volces.com/api/v3
```
