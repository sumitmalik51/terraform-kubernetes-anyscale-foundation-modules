# Demo Guide — Multi-Model Content Pipeline

Step-by-step walkthrough from an empty workspace to a deployed, auto-scaling
service on Anyscale. No HuggingFace account needed — both default models
(DistilBERT, DistilBART-CNN) are ungated and download automatically.

---

## Table of Contents

1. [Prerequisites](#step-1-prerequisites)
2. [Set Up Your Workspace](#step-2-set-up-your-workspace)
3. [Understand the Project Files](#step-3-understand-the-project-files)
4. [Install Dependencies](#step-4-install-dependencies)
5. [Run Locally](#step-5-run-locally)
6. [Test with the Client](#step-6-test-with-the-client)
7. [Deploy to Anyscale](#step-7-deploy-to-anyscale)
8. [Test the Deployed Service](#step-8-test-the-deployed-service)
9. [Monitor and Observe Autoscaling](#step-9-monitor-and-observe-autoscaling)
10. [Tear Down](#step-10-tear-down)

**Appendices**

- [A. Swapping Models](#appendix-a-swapping-models)
- [B. Using Gated HuggingFace Models](#appendix-b-using-gated-huggingface-models)
- [C. Troubleshooting](#appendix-c-troubleshooting)
- [D. Quick Reference — Commands](#appendix-d-quick-reference--commands)

---

## Step 1: Prerequisites

| Requirement | Why | How to Check |
|---|---|---|
| **Python 3.11+** | Required by Ray Serve and the local dev path | `python --version` |
| **Anyscale CLI** | Deploy to production | `anyscale --version` |
| **Anyscale account** | Access the platform | [console.anyscale.com](https://console.anyscale.com) |
| **GPU (local only)** | Sentiment + Summarizer load CUDA | `nvidia-smi` |

### Install the Anyscale CLI

```bash
pip install anyscale
anyscale login
```

> **No GPU locally?** Skip steps 5–6 and jump straight to step 7. Anyscale
> provisions A10 GPU nodes for you.

---

## Step 2: Set Up Your Workspace

### Option A: Anyscale Workspace (Recommended)

```bash
anyscale workspace create \
  --name multi-model-pipeline \
  --image-uri anyscale/ray-llm:2.56.0-py312-cu130 \
  --instance-type 1xA10-24G:36CPU-440GB

anyscale workspace connect multi-model-pipeline
```

### Option B: Local Machine

```bash
mkdir multi-model-pipeline && cd multi-model-pipeline

# Required files in this directory:
#   serve_app.py
#   service.yaml
#   compute_config_azure.yaml
#   client.py
#   requirements.txt
```

---

## Step 3: Understand the Project Files

| File | Purpose |
|---|---|
| **`serve_app.py`** | The application. Defines four Ray Serve deployments (`ContentFilter`, `SentimentClassifier`, `Summarizer`, `ContentPipeline`) that scale independently. The `WHY` comments inline explain the design. |
| **`service.yaml`** | Anyscale deploy config. Pins the named compute config (`multi-modal-2298227`), container image, and requirements. |
| **`compute_config_azure.yaml`** | Source YAML for the named compute config. Targets `odl_user_2298227_cloud` — one A10 GPU pool plus one CPU pool. |
| **`client.py`** | Test client. Functional tests + a `--throughput` load-test mode. |
| **`requirements.txt`** | Python dependencies — `transformers`, `numpy`, `fastapi`, `requests`. `torch` is intentionally absent; the image ships its own cu130 build. |

### Models Used (Both Ungated)

| Model | HuggingFace ID | Params / Size | Task | GPU |
|---|---|---|---|---|
| **DistilBERT SST-2** | `distilbert-base-uncased-finetuned-sst-2-english` | 67 M / ~250 MB | Sentiment classification | 0.25 GPU |
| **DistilBART-CNN** | `sshleifer/distilbart-cnn-12-6` | 306 M / ~1.2 GB | Text summarization | 0.25 GPU |

Both download from HuggingFace Hub on first run. No token required.

---

## Step 4: Install Dependencies

```bash
pip install -r requirements.txt
```

Installs:

- `transformers` — model loading for both DistilBERT and DistilBART-CNN
- `fastapi` — HTTP ingress for `ContentPipeline`
- `numpy`, `requests` — utility deps

> `torch` and `ray[serve]` are **not** in `requirements.txt` because the
> Anyscale image (`ray-llm:2.56.0-py312-cu130`) ships them. Pinning torch here
> would risk overriding the image's cu130 build.

---

## Step 5: Run Locally

```bash
serve run serve_app:app
```

**What happens:**

1. Ray starts a local cluster.
2. Ray Serve creates the four deployments — one replica each at `min_replicas`.
3. `ContentFilter` initializes instantly (regex compile only).
4. `SentimentClassifier` downloads DistilBERT (~250 MB) and warms up on GPU.
5. `Summarizer` downloads DistilBART-CNN (~1.2 GB) and warms up on GPU.
6. `ContentPipeline` starts the FastAPI server on port 8000.

> **First run takes 2–5 minutes** for model downloads. Subsequent runs are
> near-instant thanks to the HuggingFace cache (`~/.cache/huggingface/`).

You should see:

```
ContentFilter ready (CPU)
SentimentClassifier ready (GPU 0.25)
Summarizer ready (GPU 0.25)
ContentPipeline orchestrator ready (CPU)
```

The service is now live at **http://localhost:8000** with:

- API docs — http://localhost:8000/docs
- Health — http://localhost:8000/health

---

## Step 6: Test with the Client

In a **new terminal**:

```bash
python client.py                       # functional tests
python client.py --throughput 10       # 10 concurrent requests
```

### Expected Output

```
==============================================================
HEALTH CHECK
==============================================================
Status: 200
{ "status": "healthy" }

==============================================================
TEST 1: Normal text (should pass all stages)
==============================================================
Status: 200
{
  "status": "processed",
  "filter":    { "pii_detected": {}, "original_length": 312 },
  "sentiment": { "label": "POSITIVE", "score": 0.9987 },
  "summary":   { "summary": "Ray Serve enables ...", "input_length": 312, ... }
}

==============================================================
TEST 2: Text with PII (should redact and proceed)
==============================================================
Status: 200
{
  "status": "processed",
  "filter": { "pii_detected": { "email": 1, "phone": 1 }, ... },
  ...
}

==============================================================
TEST 3: Blocked content (should be rejected)
==============================================================
Status: 200
{ "status": "rejected", "reason": "Blocked content detected" }

==============================================================
TEST 4: Too-short text (should be rejected)
==============================================================
Status: 200
{ "status": "rejected", "reason": "Text too short (min 3 chars)" }
```

> Tests 3 and 4 demonstrate the **cost gate** — rejected content never reaches
> the GPU models.

---

## Step 7: Deploy to Anyscale

### 7a. Review the Service Config

Open `service.yaml` and verify:

- `compute_config` points at the registered named config (`multi-modal-2298227:2`).
- `image_uri` is `anyscale/ray-llm:2.56.0-py312-cu130`.
- Autoscaling limits match expected traffic.

### 7b. (Optional) Register the Compute Config

Only needed the first time, or when `compute_config_azure.yaml` changes:

```bash
anyscale compute-config create \
  -n multi-modal-2298227 \
  -f compute_config_azure.yaml
```

This bumps the version (e.g. `:2` → `:3`). Update `service.yaml`'s `compute_config:` line to match.

### 7c. Deploy

```bash
anyscale service deploy -f service.yaml
```

**What happens:**

1. Anyscale builds a container from `image_uri` + `requirements.txt`.
2. Provisions the cluster — head, GPU pool, CPU pool — per the compute config.
3. Uploads `working_dir` to the cluster.
4. Starts `serve_app:app`.
5. Assigns an HTTPS endpoint with TLS and a bearer token.

You should see:

```
Service 'multi-model-content-pipeline-2298227' deployed.
Endpoint: https://multi-model-content-pipeline-xxxxx.anyscale.com
```

> **First deploy takes 5–10 minutes** (image build + node provisioning +
> model download). Subsequent deploys reuse the cached image and HF models.

---

## Step 8: Test the Deployed Service

Grab the URL and token from the Anyscale console or via:

```bash
anyscale service list
```

Then point the client at it:

```bash
python client.py \
  --url   https://multi-model-content-pipeline-xxxxx.anyscale.com \
  --token YOUR_ANYSCALE_API_TOKEN
```

Or use `curl`:

```bash
curl -X POST https://YOUR_SERVICE_URL/analyze \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"text": "Ray Serve makes it easy to deploy ML models at scale."}'
```

---

## Step 9: Monitor and Observe Autoscaling

### Via the Anyscale Dashboard

1. [console.anyscale.com](https://console.anyscale.com) → **Services**
2. Click your service → **Deployments** tab
3. Watch replica counts change live as traffic arrives.

### Trigger Autoscaling

```bash
python client.py \
  --url   https://YOUR_SERVICE_URL \
  --token YOUR_TOKEN \
  --throughput 20
```

**Expected behavior** (per `service.yaml`'s autoscaling config):

| Deployment | Likely Movement |
|---|---|
| `ContentFilter` | 1 → 2–3 replicas (CPU, fast to add) |
| `SentimentClassifier` | Stays at 1 (single replica handles ~5 concurrent) |
| `Summarizer` | May scale 1 → 2 (~200 ms per request) |
| `ContentPipeline` | May scale 1 → 2 (handling 20 connections) |

> **Key observation:** CPU and GPU tiers scale **independently**. ContentFilter
> adds replicas while Summarizer stays put — the bottleneck differs per tier.

### Via the Ray Dashboard

```bash
# Locally
open http://localhost:8265

# On Anyscale: click "Ray Dashboard" in the service detail page
```

The **Serve** tab shows per-deployment replicas, QPS, latency percentiles, and
queued requests.

---

## Step 10: Tear Down

### Local

`Ctrl+C` in the terminal running `serve run`.

### Anyscale

```bash
anyscale service terminate multi-model-content-pipeline-2298227
```

---

## Appendix A: Swapping Models

Both deployments use the HuggingFace `transformers` library, so swapping is
mostly a one-line change to `_MODEL_ID`.

### Where to Find Compatible Models

| Source | URL | What to Look For |
|---|---|---|
| **HuggingFace Hub** | [huggingface.co/models](https://huggingface.co/models) | Filter by task tag (`text-classification`, `summarization`) |
| **Pipeline docs** | [Transformers pipelines](https://huggingface.co/docs/transformers/main_classes/pipelines) | Any pipeline-compatible classification model works for `SentimentClassifier` |
| **Seq2Seq docs** | [`AutoModelForSeq2SeqLM`](https://huggingface.co/docs/transformers/model_doc/auto#transformers.AutoModelForSeq2SeqLM) | `Summarizer` uses this; any seq2seq model is a candidate |

### How to Check If a Model Is Gated

1. Visit the model page on HuggingFace.
2. Look near the top:
   - No icon → ungated.
   - Lock icon + "Gated model" → see [Appendix B](#appendix-b-using-gated-huggingface-models).
3. Or programmatically:

```python
from huggingface_hub import model_info
print(model_info("Qwen/Qwen2.5-7B-Instruct").gated)
# False = ungated; "auto"/"manual" = gated
```

### Recommended Ungated Sentiment Models

| Model | ID | Size | Notes |
|---|---|---|---|
| **DistilBERT SST-2** (default) | `distilbert-base-uncased-finetuned-sst-2-english` | 67 M / ~250 MB | Binary pos/neg, English |
| RoBERTa Twitter | `cardiffnlp/twitter-roberta-base-sentiment-latest` | 125 M / ~500 MB | 3-class: pos / neg / neutral |
| BERT multilingual | `nlptown/bert-base-multilingual-uncased-sentiment` | 110 M / ~440 MB | 1–5 star rating, multilingual |

Update `serve_app.py`:

```python
class SentimentClassifier:
    _MODEL_ID = "cardiffnlp/twitter-roberta-base-sentiment-latest"
```

If the new model emits different labels (e.g. 3-class instead of 2), adjust
downstream code that consumes `{label, score}`.

### Recommended Ungated Summarization Models

| Model | ID | Size | Notes |
|---|---|---|---|
| **DistilBART-CNN** (default) | `sshleifer/distilbart-cnn-12-6` | 306 M / ~1.2 GB | Fast, distilled |
| BART-Large-CNN | `facebook/bart-large-cnn` | 406 M / ~1.6 GB | Higher quality, still A10-friendly |
| PEGASUS-CNN | `google/pegasus-cnn_dailymail` | 568 M / ~2.3 GB | News-tuned, different arch |
| T5-Small | `google-t5/t5-small` | 60 M / ~240 MB | Tiny, lower quality |

Update `serve_app.py`:

```python
class Summarizer:
    _MODEL_ID = "facebook/bart-large-cnn"
```

If you swap to a model that's **significantly larger** (>~4 GB), bump
`num_gpus` from `0.25` to `0.5` so it gets more VRAM.

---

## Appendix B: Using Gated HuggingFace Models

The defaults are ungated, so most users can skip this. Follow this appendix
only if you swap in a gated model (Llama, Gemma, Mistral, etc.).

### B1. Create a HuggingFace Account

[huggingface.co/join](https://huggingface.co/join) → sign up → verify email.

### B2. Accept the Model License

1. Open the model page (e.g. [`meta-llama/Llama-3.1-8B`](https://huggingface.co/meta-llama/Llama-3.1-8B)).
2. Click **Expand to review and access**.
3. Accept the license. Approval is instant for most models, up to 24 h for some.

### B3. Create an Access Token

1. [huggingface.co/settings/tokens](https://huggingface.co/settings/tokens) → **New token**.
2. Name: `anyscale-pipeline`. Type: **Read** (write isn't needed).
3. Copy the `hf_...` token.

### B4. Configure the Token

**Local development:**

```bash
export HF_TOKEN=hf_your_token_here
# or
pip install huggingface_hub && huggingface-cli login
```

**Anyscale deployment** — add an `env_vars` block to `service.yaml`:

```yaml
applications:
  - name: default
    import_path: serve_app:app
    route_prefix: /
    env_vars:
      HF_TOKEN: "hf_your_token_here"
    deployments:
      ...
```

> **Don't commit the token.** For real deployments use an Anyscale secret:
> ```bash
> anyscale secret create HF_TOKEN hf_your_token_here
> ```
> and reference it from `service.yaml` instead of inlining the value.

---

## Appendix C: Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `CUDA out of memory` | Model larger than its GPU fraction allows | Bump `num_gpus` (e.g. `0.25` → `0.5`), or pick a smaller model, or use a larger instance |
| `401 Unauthorized` from HuggingFace | Gated model without token | See [Appendix B](#appendix-b-using-gated-huggingface-models) |
| `Connection refused` on `localhost:8000` | Server still starting | Wait for the four "ready" lines — first run includes model download |
| Slow first request | Model warmup + JIT compilation | Expected on cold start; subsequent requests are fast |
| `NVIDIA driver too old (found version 12080)` in replica logs | Image's torch built for a newer CUDA than the GPU driver supports | Check `nodes.yaml` for the AKS GPU image; if the driver is older than R580, fall back to a cu128 image |
| Deployment stuck in **UPDATING** | Node provisioning or image build in progress | Anyscale console → service → **Events** tab |
| `ModuleNotFoundError` on import | A new dep wasn't added to `requirements.txt` | Add it and redeploy |

---

## Appendix D: Quick Reference — Commands

```bash
# ── Local development ──
pip install -r requirements.txt           # install deps
serve run serve_app:app                   # start server
python client.py                          # functional tests
python client.py --throughput 20          # load test

# ── Anyscale deployment ──
anyscale compute-config create -n multi-modal-2298227 -f compute_config_azure.yaml
anyscale service deploy -f service.yaml
anyscale service list
anyscale service status   multi-model-content-pipeline-2298227
anyscale service terminate multi-model-content-pipeline-2298227

# ── Test deployed service ──
python client.py --url https://YOUR_URL --token YOUR_TOKEN
python client.py --url https://YOUR_URL --token YOUR_TOKEN --throughput 20
```
